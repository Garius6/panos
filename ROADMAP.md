# Panos — Roadmap

Консолидированный план развития после релиза ADT + pattern-matching. Отражает
обсуждённые направления: generics, FFI, GC, LSP, DOD-миграция, рефакторинг
type checker'а. Стадии перечислены в порядке выполнения; зависимости и
критический путь объяснены отдельно.

**Составлен**: 2026-07-09
**Синхронизировано с TASKS.md**: 2026-07-12
**Источник**: обсуждение возможных направлений языка после MVP ADT-фичи.
Отчёт по type checker'у: `specs/001-adt-pattern-matching/reviews/type-checker-analysis.md`.

**Текущий статус** (детали — TASKS.md): готовы Стадии 0 ✅, 1 (GC) ✅,
2 (DOD Волна 1 + Diagnostics) ✅, 3 (LSP MVP) ✅, 6 (TC Волна 2) ✅.
Стадия 5 (DOD Волна 2 + LSP расширение) — частично (Symbol_Id + LSP
completions/references/rename готовы; Type_Id/SoA сознательно отложен, см.
пометку в Стадии 5 ниже). Стадии 4 (FFI-A), 7 (Generics), 8 (FFI-B), 9
(DOD Волна 3) — не начаты, разблокированы (7 и 8 требуют Стадию 6, которая
уже закрыта). Поверх исходного плана внепланово сделаны Стадии 10-17 (см.
§10 ниже и TASKS.md) — error-recovery лексера/парсера/резолвера,
объектный API фс/сеть, HTTP-клиент на Panos, for-in.

---

## 1. Граф зависимостей

```
TC Волна 1 ────┐
               ├──> Волна 2 ──> Generics ──> Prelude cleanup
               │
GC ────────────┼──> FFI-B (finalizers), long-running programs
               │
DOD Волна 1 ───┼──> LSP MVP
(spans, interning, diagnostics)
               │
TC P8 ─────────┘  (= diagnostic accumulation, объединяется с DOD Волна 1)

FFI-A (raylib) — независимо, quick demo
FFI-B (dynamic) → user-space обёртки, stdlib миграция

DOD Волна 2 (Symbol/Type IDs) → LSP hover/rename/refs
DOD Волна 3 (AST indices) — опционально, под профиль

Generics: A → B → C → D → E → F
```

### Ключевые связи

- **DOD Волна 1 diagnostic** = **TC P8**. Одна и та же работа —
  накопление ошибок в vector вместо `fmt.panicf`. Делать вместе.
- **GC** — bottleneck для FFI-B (finalizers обязательны) и long-running
  сценариев (LSP-сессии длятся часами). Инвестировать рано.
- **TC Волна 1** — 2-3 дня работы, разблокирует всё последующее. Zero
  risk. Абсолютный приоритет.
- **DOD Волна 2** зависит от TC Волна 1, но независима от GC.

---

## 2. Критический путь до LSP MVP

**✅ Достигнуто** (Стадии 0, 2, 3 закрыты — см. TASKS.md).

Самый короткий путь до user-facing milestone:

```
TC Волна 1 (2-3д)
  → DOD Волна 1 (5-7д)
    ├─> spans in tokens/AST
    ├─> string interning
    └─> diagnostic accumulation (= TC P8)
  → LSP skeleton + diagnostics + hover + go-to-def (8-10д)
```

**~2.5-3 недели** до "открыл `.ps`-файл в VS Code, вижу подсвеченные ошибки,
hover показывает типы, Cmd+Click прыгает на определение".

Это первый видимый milestone. Демонстрирует прогресс. Motivation-anchor.

---

## 3. Стадии

### Стадия 0 — Foundation cleanup (2-3 дня) ✅

**Что**:
- **TC Волна 1**: P2 helper `resolve_variant_ctor`, P3 `variant_index`
  map в Type, P5 synth cache, P12 убрать двойные `prune_type`, P13
  `BASE_TYPES` map + fix `Никогда`, P14 убрать `Match_Arm_Info` wrapper,
  P15 унифицировать `variant_calls`+`variant_idents` в `variant_ctors`.

**Зачем**:
- −209 строк type checker'а, устраняет тройной дубликат Enum_Variant-логики.
- Убирает утечки памяти synth-функций.
- Fix бага `Никогда` в аннотации типа.
- Zero risk — все правки мелкие и локальные.

**Checkpoint**: 38/38 тестов зелёные. `test.ps` без регрессий. type
checker обозрим (2150 строк вместо 2359).

---

### Стадия 1 — Runtime memory model (GC) (2 недели) ✅

**Что**:
- `^Panos_String` обёртка для runtime-строк (compile-time strings остаются
  arena view).
- `GC_State` + allocator interface на Odin's `mem.Allocator`.
- `GC_Header` layout + `gc_new[T]` helpers через compile-time `when`.
- Value walker для 11 вариантов union (hand-crafted, force complete switch).
- Root walker: `vm.stack + vm.frames + registry`.
- Sweep + adaptive threshold (2x-of-live).
- Migration `new(X)` → `gc_new(X)` в vm.odin.
- GC stats + force_gc для тестов.

**Зачем**:
- Разблокирует robust FFI (finalizers для C-объектов).
- Long-running scenarios: LSP-сессия, REPL, watchers.
- Убирает arena bloat в runtime.
- Программы-циклы больше не растут по памяти линейно.

**Prerequisite**: Стадия 0.

**Порядок работ**:
1. `^Panos_String` (0.5 дня).
2. `GC_State` + allocator interface (1 день).
3. Header layout + `gc_new` helpers (0.5 дня).
4. Value walker (1 день).
5. Root walker (0.5 дня).
6. Sweep + adaptive threshold (1 день).
7. Migration в vm.odin (0.5 дня).
8. Stress tests + tuning (2 дня).

**Checkpoint**: программа с миллионом allocation'ов в цикле — память не
растёт. Все существующие тесты проходят. Memory-tracker не показывает
runtime-leaks.

**Effort**: ~8-10 дней.

**Архитектурное дополнение (выполнение)**: голого mark-sweep поверх
`new()`/`free()` оказалось недостаточно для собственного checkpoint'а —
peak RSS на CLI-прогоне рос линейно с числом итераций (164MB → 968MB на
1M → 6M итераций), хотя внутренний учёт GC (bytes_allocated, live_objects)
был идеально стабилен цикл к циклу. Причина — разрыв между "logically
freed" и "OS-visible память переиспользована": `free()` возвращает блок в
malloc, но под sustained allocation churn ОС/malloc не гарантируют быстрый
reuse тех же страниц под аллокации того же размера. Добавлен object
pooling — free-list per типу вместо реального `free()`, `resize()` вместо
`make()` для переиспользуемых `.elements`/`.entries`/`.fields`. Результат:
peak RSS стал плоским (7.65MB одинаково на 1M/3M/6M итераций для
struct/array-нагрузки). Для string-heavy нагрузки пока пулится только
заголовок `Panos_String`, не byte-буфер переменной длины — рост памяти
есть, но не катастрофический; полноценный size-class аллокатор для строк
не сделан, задел на будущее. См. TASKS.md §Стадия 1 для деталей.

---

### Стадия 2 — DOD Волна 1 + Diagnostic accumulation (1.5 недели) ✅

**Что** (объединено, потому что одна и та же работа):
- **Spans** в токенах и AST (`Span {file_id: u16, start: u32, end: u32}`).
- **String interning** (`Interned :: distinct u32`, `String_Interner`).
- **Diagnostic accumulation** = TC P8: `Diagnostic` struct,
  `Type_Ctx.diagnostics`, `TY_POISON` тип, replace ~100 `fmt.panicf` на
  `report(ctx, span, ...)`.

**Зачем**:
- Spans — обязательный prerequisite LSP (position queries, error
  highlighting).
- Interning — cheap win, дедупликация, ускоряет сравнение имён.
- Diagnostics — multi-error UX + LSP publishDiagnostics.

**Prerequisite**: Стадия 0 (не Стадия 1 — GC не нужен для этого).

**Порядок работ**:
1. `Span` struct + retrofit в token'ы (1 день).
2. Span в AST-узлы (2 дня, ~15 struct'ов).
3. `String_Interner` + `Interned` type (0.5 дня).
4. Migration `Ident_Expr.name`, `Symbol.name` на `Interned` (0.5 дня).
5. `Diagnostic` struct + `Type_Ctx.diagnostics` (0.5 дня).
6. `TY_POISON` тип + правила non-cascade (0.5 дня).
7. Migration ~100 `fmt.panicf` → `report(ctx, span, ...)` (1.5 дня).
8. `typecheck_program` в конце: если diagnostics не пуст — печать всех +
   non-zero exit (0.5 дня).

**Тонкость**: миграция exact-match e2e тестов. `testing.expect_assert`
работает через panic, не через diagnostic vector. Ввести
`expect_diagnostic(t, source, expected_msg)` helper.

**Checkpoint**: программа с 5 ошибками показывает все 5 сразу, каждая с
span'ом (line:col). AST-узлы имеют span. Строки-идентификаторы дедуплицированы.

**Effort**: ~7-9 дней.

**Архитектурная развилка: constraint-based inference (обсуждено, отклонено
для этой стадии)**. Рассматривался переход на two-phase inference
(generate constraints → solve batch'ем) вместо текущего eager unify
(`infer_expr` унифицирует на месте по мере обхода). Вывод: это не
отменяет нужду в TY_POISON — контрадикторный constraint всё равно
оставляет type variable без валидного binding'а, и все остальные
constraint'ы, ссылающиеся на неё, каскадно "ломаются" ровно так же, как
при eager-подходе. Зрелые реализации (TypeScript, Rust — `TyKind::Error`)
несут error-sentinel через solver по той же причине, просто он живёт в
solver'е, а не в разрозненных `report()`-вызовах. Реальная выгода
constraint-based — не в подавлении каскадов, а в том, что batch-solving
= естественный субстрат для let-generalization (`Type_Scheme`,
`generalize`, `instantiate`), которая нужна для generics. Решение:
**не делать здесь** — Стадия 2 остаётся eager unify + TY_POISON (проще,
меньше risk, тот же diagnostic-accumulation результат). Constraint-based
generate-then-solve рассмотреть **в Стадии 7 (Generics)**, где он и так
нужен под capstone-фичу — см. пометку там.

---

### Стадия 3 — LSP MVP (1.5 недели) ✅

**Что**:
- LSP server skeleton (JSON-RPC 2.0 over stdio, initialize/shutdown).
- Feature: `textDocument/publishDiagnostics` on save/change.
- Feature: `textDocument/hover` — тип под курсором.
- Feature: `textDocument/definition` — go-to-def через `node_symbols`.
- VS Code extension skeleton (~100 строк TypeScript).
- Position mapping UTF-16 ↔ UTF-8 (LSP использует UTF-16 offset'ы).

**Зачем**:
- User-facing milestone.
- Демонстрирует прогресс.
- Проверяет DOD Волна 1 в реальном use case.

**Prerequisite**: Стадия 2.

**Порядок работ**:
1. Server skeleton + JSON-RPC framing (1 день).
2. Full-reparse on didChange (простейший цикл) (1 день).
3. publishDiagnostics: mapping `Diagnostic` → LSP Diagnostic (1 день).
4. hover: position-to-node search + type formatting (2 дня).
5. go-to-definition: Symbol → declaration span (1 день).
6. VS Code extension (registration, activation) (1 день).
7. Position mapping UTF-16 ↔ UTF-8 (0.5 дня).
8. E2E тесты через `vscode-languageserver-testkit` (1.5 дня).

**Отложить в Стадию 5**: completions, find-references, rename — требуют
Symbol IDs.

**Checkpoint**: открываешь `.ps`-файл в VS Code, видишь красные
подчёркивания ошибок с сообщениями. Hover над `Круг` показывает
`Круг(Число) -> Фигура`. Cmd+Click прыгает на определение функции.

**Effort**: ~8-10 дней.

**Отклонения от плана (выполнение)**: VS Code extension заменена на
Neovim-интеграцию (`editors/nvim/`) по прямому указанию пользователя —
проверено кастомным Python JSON-RPC клиентом + headless Neovim вместо
vscode-инструментария. Известное на момент MVP ограничение
"go-to-definition только в текущем файле" закрыто позже (пост-MVP, по
запросу): LSP строит полноценный `core.Module_Graph` per документ с
in-memory overrides для открытых буферов — многофайловый go-to-def и
diagnostics по всему графу импортов, не только entry-файлу. Детали —
TASKS.md §Стадия 3 "Граф импортов в LSP".

---

### Стадия 4 — FFI фаза A: raylib demo (3 дня)

**Что**:
- `raylib_bindings.odin` — `foreign import raylib "system:raylib"` + 50
  функций (InitWindow, DrawCircleV, GetMouseX/Y, Colors, Vector2).
- Panos-модуль `графика` в `stdlib.odin` (thin wrappers → C).
- Демо-программа: pong или snake в `demos/`.

**Зачем**:
- Quick user-visible win.
- Показывает язык живым.
- Проверяет FFI-концепцию до investment в FFI-B.

**Prerequisite**: нет. Независимо от других стадий.

**Порядок работ**:
1. Bindings + Colors/Vector2 struct переводы (1 день).
2. Panos-модуль `графика`, registration в call_builtin (1 день).
3. Demo-программа (pong) + polish (1 день).

**Checkpoint**: `just run demos/pong.ps` — играбельный pong. Публикация
gif'а в README.

**Effort**: 3 дня.

---

### Стадия 5 — DOD Волна 2 + LSP расширение (2-3 недели) (частично ✅)

**Что**:
- **Symbol IDs**: `Symbol_Id :: distinct u32` + `Symbol_Store` SoA
  (columns: names, kinds, scope_ids, module_ids, owner_types, decls, flags).
- **Type IDs**: `Type_Id :: distinct u32` + `Type_Store` SoA.
- Migration resolver → store-based access (`^Symbol` → `Symbol_Id`).
- Migration type checker → `Type_Id`.
- Migration compiler.
- **LSP completions**: scope-aware enumeration.
- **LSP find-references**: `Symbol_Id → [dynamic]Usage_Site` таблица.
- **LSP rename**: usage table + edit generation через LSP `WorkspaceEdit`.

**Зачем**:
- Cross-reference table становится тривиальной колонкой.
- Rename обновляет один column.
- SoA даёт cache-linear iteration ("все Enum_Variant" = scan одной
  колонки).
- LSP получает полный feature set.

**Prerequisite**: Стадия 2 (spans, interning).

**Порядок работ**:
1. `Symbol_Id` + `Symbol_Store` (все columns) (2 дня).
2. Migration `^Symbol` → `Symbol_Id` в resolver (2 дня).
3. Migration в type checker (1 день).
4. Migration в compiler (1 день).
5. `Type_Id` + `Type_Store` (2 дня).
6. Migration (2 дня).
7. LSP completions (2 дня).
8. LSP find-references (1 день).
9. LSP rename (2 дня).

**Checkpoint**: LSP имеет 5 базовых фич. Rename в редакторе обновляет все
использования. Symbol table хранится SoA-стилем — обозримо в debugger'е.

**Effort**: ~15-20 дней. Значительный рефакторинг, но каждый шаг
измеримый и коммит'абельный.

**Архитектурное решение (выполнение)**: Symbol_Id реализован как индекс в
`[dynamic]Symbol` (AoS + handle), а не колоночный SoA — `Symbol` не хранит
крупных встроенных массивов, копия по значению дешева, а стабильный ID уже
даёт то, что реально требовалось LSP-фичам (Symbol_Id → usage-таблица).
Полная SoA-раскладка отложена вместе с Type_Id.

Type_Id/Type_Store **сознательно не реализован** в рамках этого прохода.
`Type` — не просто хэндл: рекурсивная структура с pointer-identity
семантикой (`unify_types`/`types_are_equal` через `==`, mutable `binding`
для InferVar в стиле union-find, глобальные синглтоны `TY_NUM`/`TY_POISON`),
150+ точек использования в 2700-строчном `type_cheker.odin`. Перевод на
ID-based store — это переписывание модели вывода типов, а не механическое
переименование, с реальным риском тихо сломать unification. Ни одна из
LSP-фич Стадии 5 (completions/find-references/rename) не требует Type_Id —
он чисто перформансный (cache-linear iteration). Оставлен как отдельная,
не блокирующая задача.

---

### Стадия 6 — TC Волна 2 (1 неделя) ✅

**Что**:
- **P1** — split `infer_expr` на per-case процедуры:
  `infer_call_expr`, `infer_match_expr`, `infer_property_expr`,
  `infer_binary_expr`, `infer_ident_expr`.
- **P4** — унификация 7 side-tables (`variant_calls`, `variant_idents`,
  `is_constructor`, `builtin_calls`, `method_calls`, `collection_calls`,
  `interface_calls`) в единый `Call_Info` с `Call_Kind` enum.
- **P6** — data-driven `builtin_constructor_type` +
  `standard_method_type` (таблица + handler'ы для сложных случаев).

**Зачем**:
- Prerequisite для generics: `infer_expr` в текущем состоянии не выдержит
  generalize/instantiate вставки.
- −150 строк boilerplate.
- File разделится на управляемые части (~1500 строк вместо 2150).

**Prerequisite**: Стадия 5 (Symbol_Id/Type_Id упрощают split).

**Порядок работ**:
1. Split `infer_expr` (2 дня).
2. `Call_Info` + migration compiler (2 дня).
3. Data-driven builtins + methods (2 дня).

**Checkpoint**: type_cheker.odin ≤ 1500 строк. `infer_expr` = 200-строчный
диспатчер. Одна карта `call_infos` вместо семи.

**Effort**: ~6 дней.

---

### Стадия 7 — Generics (2-3 недели)

**Что**:

- **Phase A** ✅ — implicit rank-1 полиморфизм для лямбд (1 день).
- **Phase B** ✅ — явные generic-функции: `функ имя[T](x: T) -> T` (2 дня).
- **Phase C** ✅ (только struct, см. заметку ниже) — generic struct/interface:
  `тип Пара[A, B] = структура` (2 дня).
- **Phase D** ✅ (см. заметку ниже) — generic ADT: `тип Дерево[T] =
  перечисление ...` (1 день).
- **Phase E** ✅ (методы; generic-интерфейсы отложены, см. заметку ниже) —
  `реализация Список[T] ... конец` (2-3 дня).
- **Phase F** — prelude cleanup: `Опция(T)` и `Результат(T, E)`
  переписаны как user-declared ADT в prelude-модуле. Убирает
  `Type_Kind.Option/.Result` special-case (1 день).

**Зачем**:
- Language выразительность (полиморфизм ранга 1).
- Prelude cleanup удаляет ~200 строк special-case кода в type checker'е.
- Standard ML / OCaml level polymorphism.

**Prerequisite**: Стадия 6 (`infer_expr` split).

**Ключевые концепции**:
- `Type_Scheme :: struct {forall: [dynamic]int, body: Type_Id}` (тип-схема).
- `generalize(env, type) -> scheme` — при top-level let.
- `instantiate(scheme) -> type` — при каждом использовании.
- `substitute(type, subst) -> type` — обход Type-структуры.
- Type erasure at bytecode — VM не меняется, generic'и растворяются в
  байткоде.

**Архитектурное решение: constraint-based inference (generate → solve)**.
Здесь, а не в Стадии 2, стоит перейти от текущего eager unify
(`infer_expr` унифицирует по мере обхода AST) на two-phase: сначала
проход генерирует constraint'ы (`Equal(t1, t2)` и т.п.) без немедленного
решения, потом отдельный solver прогоняет их batch'ем. Причина именно
здесь: `generalize`/`instantiate` из let-polymorphism естественно
формулируются как "собрать constraint'ы внутри let-биндинга → solve →
обобщить свободные переменные" — batch-solving даёт это почти бесплатно,
тогда как eager-unify (текущий Q4-подход) требует отдельной ad-hoc
логики generalization. **Важно**: constraint-based НЕ отменяет нужду в
TY_POISON/error-sentinel (см. пометку в Стадии 2) — контрадикторный
constraint всё так же оставляет переменную без binding'а, и solver
должен нести тот же error-placeholder через граф constraint'ов, чтобы не
каскадить производные ошибки. Просто здесь этот механизм естественно
встраивается в solver, а не прикручивается отдельно.

**Заметка по Phase A (сделано)**: реализовано на текущем eager-unify, БЕЗ
перехода на constraint-based inference — для узкого случая let-polymorphism
у лямбд eager-unify достаточно (см. `Type_Scheme`/`generalize`/
`instantiate_type` в core/type_cheker.odin). Правило generalize нарочно
узкое: обобщается любой InferVar, unbound после prune_type и достижимый из
типа лямбды, без анализа охватывающей среды — корректно только пока
top-level `функ` не имеет инференса (сигнатура строго из аннотаций).
**Если Phase B введёт инференс сигнатур без аннотаций до того, как появится
constraint-based solver — это правило нужно пересмотреть** (over-eager
generalization / value restriction). Переход на constraint-based (генерация
→ solve) остаётся нерешённым архитектурным вопросом для Phase B+, см. ниже.

**Заметка по Phase B (сделано)**: assumption из заметки Phase A выше НЕ
нарушен — сигнатуры generic-функций остаются полностью явными (`x: T`,
`-> T` — обычные аннотации, `T` просто резолвится в InferVar вместо
"неизвестный тип", инференса сигнатур без аннотаций не появилось). Схема
строится один раз при регистрации сигнатуры (не из инференса тела, как у
Phase A) и кладётся в ТУ ЖЕ карту `symbol_schemes` — место вызова
(`infer_call_expr`/`infer_ident_expr`) не изменилось ни строкой: механизм
инстанциации Phase A подхватывает generic-функции автоматически, раз их
символ идёт по тому же общему пути. `T` внутри `Массив(T)`/`Опция(T)`
и т.п. резолвится рекурсивно тем же кодом — отдельной поддержки не
потребовалось. Generic-методы (`реализация X ... функ м[T]`) явно
отклоняются парсером — это Phase E.

**Заметка по Phase C (сделано, только struct)**: generic-интерфейсы
сознательно отложены — contract-matching поверх инстанцированных сигнатур
методов оказался бы сравним по объёму с Phase E, не влез бы в один
разумный PR вместе со структурами. Найдена и закрыта архитектурная дыра,
которой не было в Phase A/B: `unify_types`/`types_are_equal` сравнивают
`.Struct` ТОЛЬКО по identity указателя (не по имени/структурно) — без
кэша каждое текстуальное вхождение `Пара(Число, Строка)` получало бы свой
`^Type`-объект, и `пер p: Пара(Число,Строка) = Пара(1, "a")` (самый
естественный способ написать код с generic-структурой) не типизировался
бы. Добавлен `Type_Ctx.generic_instance_cache` — тот же паттерн, что уже
был у `synth_enum_cache` для Опции/Результата. Заодно починен молчаливый
баг: `Тип(Аргумент)` на НЕ-generic структуре раньше стирался в `Пусто`
без единой ошибки (у `resolve_type_node`'s `Type_Generic`-ветки не было
fallback'а) — теперь либо инстанцирует generic, либо репортит понятную
ошибку. `реализация` на generic-структурах явно отклоняется — Phase E.

**Заметка по Phase D (сделано)**: значительно вышло за исходную оценку
"1 день", т.к. рекурсивные ADT (`Дерево[T]` ссылается на себя же в
`Узел(T, Дерево(T), Дерево(T))`) вскрыли три проблемы, каждая — блокер:
(1) `unify_types`/`types_are_equal` не имели case для `.Enum` вообще —
свитч проваливался, функция возвращала `true` БЕЗУСЛОВНО для любых двух
разных enum-типов; предсуществующая дыра типобезопасности, не связанная с
generics (подтверждено живым тестом ДО фикса); (2) канонизация
конструктора structs (Phase C) строила ключ кэша по порядку ПОЛЕЙ, а
explicit-аннотация — по порядку ЗАГОЛОВКА `[A, B]` — расходятся, если поля
объявлены не в порядке заголовка (латентный баг, не пойман тестами Phase
C); (3) самоссылающиеся generic-типы (`Список[T]` со `следующий:
Опция(Список(T))`) вызывали SIGSEGV — обходчики `^Type`-дерева
(`collect_free_infer_vars`/`instantiate_type`) не были готовы к
циклическим структурам. Все три пофикшены: `.Enum` добавлен в
identity-only case; единый `collect_instance_args` для обоих путей
канонизации; cycle-safe memoized deep copy (`visited`-карты) в
`collect_free_infer_vars`/`instantiate_type`/`unify_types` + новое поле
`Type.generic_origin` для структурного fallback'а при сравнении двух
разных (пока не канонизированных) инстанциаций одного generic-объявления.
Конструктор варианта — только `Тип.Вариант(...)` (Стадия 18, bare
`Вариант(...)` не резолвится), T выводится из аргументов, как и у structs.
Zero-payload-вариант с выводом T только из внешней аннотации (без
аргумента) — вне scope, требует push-down expected-типа в `check_expr`.

**Заметка по Phase E (сделано, только методы)**: `реализация Список ...
конец` — БЕЗ `[T]` в заголовке `реализация` (это неверно предполагал
черновой синтаксис из ROADMAP — `[T]` не парсится и не нужен, целевой тип
уже известен generic по своей декларации). Найдена архитектурная ловушка,
не совпадавшая с первоначальным планом "просто убрать rejection": если
типы методов резолвить один раз против шаблонных InferVar владельца (как
для обычных полей/сигнатур), то первый же ВЫЗОВ метода зацементировал бы
T шаблона навсегда через structural fallback в `unify_types` (Phase D,
`generic_origin`), ломая все последующие вызовы с другим T. Фикс: методы
generic-типов получают собственную `Type_Scheme` (тем же способом, что
`generalize` уже строит для конструкторов — `это: Коробка`, bare, резолвится
в сам шаблонный `^Type`, и discovery проходит внутрь него без изменений) и
инстанцируются заново на каждый вызов через `instantiate_scheme` — та же
защита, что уже есть у лямбд/функций/конструкторов с Phase A. Заодно
`instantiate_type` начал копировать `.methods` из шаблона в инстанциации
(раньше — всегда пустая карта, реализация была явно отклонена).
Generic-интерфейсы (`реализация ИнтерфейсX для Список`) по-прежнему узко
отклоняются — независимое решение Phase C, не отменено.

**Порядок работ**:
1. Phase A ✅: implicit rank-1 (1 день).
2. Phase B ✅: явные generic functions + syntax `[T]` (2 дня).
3. Phase C ✅: generic structs (интерфейсы отложены, 2 дня).
4. Phase D ✅: generic ADT + 3 связанных бага (identity unify для Enum,
   кэш-ключ порядка полей, циклические типы) — сильно больше 1 дня.
5. Phase E ✅: impl over generic (методы; интерфейсы отложены, 2-3 дня).
6. Phase F: prelude cleanup (1 день).
7. E2E тесты + docs (2 дня).

**Checkpoint**: `функ первый[T](xs: Массив(T)) -> Опция(T)` работает.
Опция и Результат — обычные user-declared ADT. Type checker без
special-case для них.

**Effort**: ~11-14 дней.

---

### Стадия 8 — FFI фаза B: dynamic (3-4 недели)

**Что**:
- Грамматика `внешний "libc" функ open(путь: КСтрока, флаги: Число_32) -> Число_32`.
- FFI-типы: `Число_32`, `Число_32_ff`, `КСтрока`, `Указатель(T)`, `ff_структура`.
- Static-linked libffi в бинарник Panos.
- Type descriptor builder (Panos type → `ffi_type`).
- Marshalling: primitives, strings, structs-by-value.
- Opcode `Call_Foreign` + VM handler.
- Callback'и через `ffi_closure` (runtime-generated trampolines).
- Memory ownership аннотации: `(владеет_я)` / `(владеет_C)` — используют GC
  finalizers для `владеет_я` случая.
- SIGSEGV recovery: signal handler, попытка вернуть `Неудача(Ошибка(...))`.
- Постепенная миграция stdlib: `фс`, `ос` из host'а → Panos + FFI.
- Обёртка raylib на Panos-стороне (замена FFI-A host-bindings).

**Зачем**:
- User-space обёртки любых C-либ без host-recompile.
- Community-driven ecosystem.
- Тoньшание транслятора.
- Профессиональная планка (LuaJIT FFI-level).

**Prerequisite**:
- Стадия 1 (GC finalizers обязательны).
- Стадия 6 (TC handles `внешний` через существующий Call_Info).

**Порядок работ**:
1. Грамматика `внешний` + FFI-типы (2 дня).
2. libffi bindings в Odin (0.5 дня).
3. Type descriptor builder (2 дня).
4. Primitive marshalling (1 день).
5. Struct-by-value marshalling (2 дня).
6. String/pointer/opaque handles (1 день).
7. `Call_Foreign` opcode + VM (1 день).
8. Тесты через libc printf/getpid (1 день).
9. Runtime error handling (1 день).
10. Callback'и через ffi_closure (3-4 дня).
11. Memory ownership + finalizers integration (2 дня).
12. Обёртка raylib на Panos-стороне (2 дня).
13. Обёртка libc `фс` (2 дня).
14. Docs (1 день).

**Checkpoint**: демо-программы на Panos + raylib — только `.ps`-файлы +
FFI-декларации. Ноль host-модификаций для новых C-либ. `stdlib::фс`
переписан как Panos-модуль на FFI.

**Effort**: ~15-20 дней.

---

### Стадия 9 (опционально) — DOD Волна 3 + инкремент (по нужде)

**Что** (только если профиль требует):
- **AST индексы**: SoA `Ast_Storage` (nodes массив + per-kind data pools).
  Замена `Expr :: union {^X}` на `Ast_Node_Id`. ~10-14 дней.
- **TC инкрементальность**: split symbol_types на readonly + derived,
  сохранение checkpoint'ов между запусками LSP.
- **Incremental parsing**: tree-sitter-style edit deltas.
- **Persistent LSP cache**: сохранять между сессиями.

**Когда делать**:
- LSP на 10k+ line файлах лагает.
- Sub-100ms latency становится требованием.
- Появляется мультифайл-project scale.

**Не сейчас**: over-engineering для файлов до 1k строк, что покрывает
99% Panos-программ. Cache-miss от pointer-hop реальный, но не dominant
cost.

**Effort** (если понадобится): ~4-5 недель.

---

### Стадии 10-17 — вне очереди (не было в исходном плане) ✅

Между закрытием Стадии 6 и началом Стадии 7 практика подкинула запросы
пользователя, не предусмотренные исходным планом — все закрыты, каждая со
своим коммитом. Полное описание, найденные попутные баги и verification —
в TASKS.md (там же ссылки на конкретные коммиты).

- **Стадия 10** — Error-recovery для parser/resolver (Hole-узлы): lexer.odin
  тоже переведён на accumulate-not-panic позже, в Стадии 12 — раньше это
  был единственный оставшийся "panicking" проход всего пайплайна.
- **Стадия 11** — Объектный API для `фс`/`ввод_вывод`: `File_Value`
  хэндлы (`фс.открыть` → `.прочитать`/`.записать`/`.закрыть`) вместо
  одноразовых функций, с GC-финализатором на незакрытых дескрипторах.
- **Стадия 12** — Lexer error-recovery (закрывает то, что было отложено в
  Стадии 10) + два критичных бага, всплывших из-за самого этого
  восстановления: nil-сегфолт в `TokenStream` на физическом EOF, и `не X`
  (логическое отрицание), компилировавшееся в no-op.
- **Стадия 13** — Настоящий TOML-парсер на Panos (`std/кодирование/toml.ps`)
  + третий критичный баг: `реализация <Перечисление>` (impl-блок методов
  на enum, не только на структуре) сегфолтила — теперь полноценно
  поддержана.
- **Стадия 14** — Модуль `сеть`: TCP-клиент (`сеть.подключиться`), тот же
  объектный паттерн, что у файлов.
- **Стадия 15** — `std/сеть/http.ps`: простой HTTP/1.1-клиент, написанный
  на самом Panos поверх TCP-клиента (не встроенный host-модуль).
- **Стадия 16** — HTTP: заголовки запроса/ответа, query-параметры
  (percent-encoding), статус-хелперы. Попутно — `Соответствие.записи()`
  (единственный способ обойти произвольную Map без for-in).
- **Стадия 17** — for-in (`для x в expr цикл...конец`) как чистый
  parser-level sugar (ноль изменений в resolver/type_cheker/compiler/vm)
  + попутный фикс: `если`/`пока` не изолировали scope в резолвере — баг
  всего языка, не только for-in.

---

## 4. Timeline

Solo, full-time:

| Стадия | Effort |
|--------|--------|
| 0. Foundation cleanup | 2-3 дня |
| 1. GC | 2 недели |
| 2. DOD Волна 1 + Diagnostics | 1.5 недели |
| 3. LSP MVP | 1.5 недели |
| 4. FFI-A raylib demo | 3 дня |
| 5. DOD Волна 2 + LSP расширение | 2-3 недели |
| 6. TC Волна 2 | 1 неделя |
| 7. Generics | 2-3 недели |
| 8. FFI-B dynamic | 3-4 недели |
| **Итого до Стадии 8** | **~4 месяца** |

Part-time (вечера + выходные): **6-8 месяцев**.

Таблица — исходные оценки, без учёта Стадий 10-17 (вне плана, см. §3
выше) — они делались параллельно/между основной линией, не входят в этот
timeline.

---

## 5. Milestone'ы

- **Через 3 недели**: LSP MVP + demo. Первый публичный анонс возможен.
  Ошибки подсвечены в VS Code, hover работает, go-to-def прыгает.
  **✅ Достигнуто** (VS Code заменён на Neovim — см. Стадия 3).
- **Через 6 недель**: Стадия 5 закрыта. LSP полный (5 фич), GC работает,
  FFI-A демо в README. Позиционирование "usable language".
  **Частично**: GC ✅, LSP completions/references/rename ✅ (Symbol_Id),
  но Type_Id сознательно отложен (см. Стадия 5) и FFI-A ещё не начат.
- **Через 10 недель**: Generics. "Serious language" territory. Опция и
  Результат — user-declared ADT. **Не начато** — вместо этого сделаны
  Стадии 10-17 (error-recovery, объектный API, сеть/HTTP, for-in),
  Generics всё ещё впереди.
- **Через 4 месяца**: FFI-B. Community-driven ecosystem возможна.
  Транслятор тоньше — stdlib переезжает в Panos-код. **Не начато** —
  частичный прообраз уже есть (std/кодирование/toml.ps, std/сеть/http.ps
  написаны на самом Panos), но полноценный FFI (Стадия 8) не начат.

---

## 6. Правила приоритизации

1. **Не начинать N+1, пока N не закрыта**. Каждая стадия — self-contained,
   commit'абельная. Kanban discipline.
2. **User-facing progress каждые 2-3 недели**. LSP MVP → раylib демо →
   completions → generics — каждое видимо снаружи.
3. **GC — единственный prerequisite для FFI-B**. Всё остальное — плюс-минус
   независимо, но GC блокирует finalizers.
4. **Type-checker рефакторинг растянут по фазам** (Волна 1 в Стадии 0,
   Волна 2 в Стадии 6). Не делать в один заход — каждая волна
   разблокирует разное. Волна 1 сама по себе; Волна 2 нужна перед
   generics.
5. **DOD растянут аналогично** (Волна 1 в Стадии 2, Волна 2 в Стадии 5).
   Волна 3 (AST indices) — опциональна.
6. **FFI разбит на два prong'а**: A для demo (quick, 3 дня), B для
   инфраструктуры (deep, 3-4 недели).
7. **Один "риск"-этап за раз**. GC (Стадия 1) — большой риск памяти;
   generics (Стадия 7) — большой риск типов; FFI-B (Стадия 8) — большой
   риск segfault'ов. Не смешивать.

---

## 7. Связанные документы

- **Type checker анализ**: [`specs/001-adt-pattern-matching/reviews/type-checker-analysis.md`](specs/001-adt-pattern-matching/reviews/type-checker-analysis.md)
  — детальный разбор Волн 1-3 рефакторинга, приоритизация P1-P15,
  прогнозируемая экономия строк.
- **ADT + pattern-matching (реализовано)**: `specs/001-adt-pattern-matching/`
  — плановые артефакты завершённой фичи.
- **Design notes**: `lang-design-notes.md` — исторические заметки о
  дизайне языка.
- **Синтаксис**: `docs/language.md` — user-facing грамматика.
- **AGENTS.md**: конвенции проекта, команды сборки/тестов.

---

## 8. Что убрано / отложено

**Убрано полностью**:
- Lisp frontend и multi-language runtime (обсуждалось, решено не делать).
- Backend abstraction (нужна была только для Lisp).
- Cross-language calls между Panos и Lisp.
- Tail call optimization (не нужна без Lisp — Panos не требует TCO).

**Отложено (может вернуться)**:
- TC Волна 3 полная (Ctx split, incremental typecheck сверх diagnostics)
  — только под LSP scale-issues.
- DOD Волна 3 (AST indices) — только под perf-issues.
- Generational GC / write barriers — только если long-running сценарии
  тормозят.
- FFI-C (codegen из C-заголовков) — не даёт ничего сверх B при большей
  сложности.

---

## 9. Ключевые архитектурные принципы

Сохраняются от предыдущих решений (Constitution v1.0.0):

- **Think Before Coding**: assumptions explicit, tradeoffs surfaced.
  Развилки закрываются явно.
- **Simplicity First**: минимум кода на задачу. Не строить абстракций
  под гипотетическое будущее.
- **Surgical Changes**: правки только в затронутых файлах. Никаких
  drive-by улучшений.
- **Функциональный стиль**: чистые функции стадий, отсутствие global
  mutable state. Отклонения документируются в plan.
- **Русскоязычные диагностики**: `Type Error:`/`Runtime Error:` префиксы
  английские (соглашение), тело — русское.
- **Commit messages**: русский, без упоминания AI.
