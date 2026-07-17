# Panos — Roadmap

Консолидированный план развития после релиза ADT + pattern-matching. Отражает
обсуждённые направления: generics, FFI, GC, LSP, DOD-миграция, рефакторинг
type checker'а. Стадии перечислены в порядке выполнения; зависимости и
критический путь объяснены отдельно.

**Составлен**: 2026-07-09
**Синхронизировано с TASKS.md**: 2026-07-16
**Источник**: обсуждение возможных направлений языка после MVP ADT-фичи.
Отчёт по type checker'у: `specs/001-adt-pattern-matching/reviews/type-checker-analysis.md`.

**Текущий статус** (детали — TASKS.md): готовы Стадии 0 ✅, 1 (GC) ✅,
2 (DOD Волна 1 + Diagnostics) ✅, 3 (LSP MVP) ✅, 6 (TC Волна 2) ✅, 22
(Сравниваемое/Равнозначное — operator sugar) ✅, 23-Арифметика
(Складываемое/Вычитаемое/Умножаемое/Делимое — operator sugar) ✅,
23-Печатаемое (полиморфный печать/строка через Печатаемое + structural
dump fallback) ✅, 23-Копируемое (`.клонировать()`, обычный прямой вызов
метода, бесплатно на существующей инфраструктуре) ✅, 27 (`конст` —
неизменяемые биндинги, + параметры функций/лямбд immutable по
умолчанию) ✅, 28 (generic-интерфейсы) ✅, 23-Итерируемое (iterator
protocol, `For_In_Stmt`-рефакторинг for-in) ✅.
Стадия 5 (DOD Волна 2 + LSP расширение) — частично (Symbol_Id + LSP
completions/references/rename готовы; Type_Id/SoA сознательно отложен, см.
пометку в Стадии 5 ниже). Стадии 4 (FFI-A), 7 (Generics), 8 (FFI-B), 9
(DOD Волна 3) — не начаты, разблокированы (7 и 8 требуют Стадию 6, которая
уже закрыта). Поверх исходного плана внепланово сделаны Стадии 10-21 (см.
§3 ниже и TASKS.md) — error-recovery лексера/парсера/резолвера, объектный
API фс/сеть, HTTP-клиент на Panos, for-in, namespace-фикс вариантов,
Пусто-функции, LSP crash-фиксы, for-in диагностика.
**Стадия 23 ЗАКРЫТА ПОЛНОСТЬЮ**: Арифметика ✅, Печатаемое ✅,
Копируемое ✅, Итерируемое ✅ (потребовала prerequisite — см. Стадию 28
ниже). По-умолчанию и Хешируемое ВЫБРОШЕНЫ из плана — обе оказались
интерфейсами без реального потребителя/подсистемы под ними (мотивация
спекулятивна, см. §3 для деталей по каждой).
Стадия 24 (lightweight processes, Elixir/Akka-style actor model —
дважды пересмотрена: CSP-каналы первого раунда заменены на actor model)
✅ ЗАКРЫТА ПОЛНОСТЬЮ (см. §3 ниже) — `запусти`/`получить`/`отправить`/
`себя`, `Процесс(T)`, round-robin scheduler с suspend/resume,
copy-on-send (reflective + Копируемое-override), GC multi-process
root-walking, 8 e2e-тестов. Стадия 25
(интерфейсы для перечислений) ✅ закрыта — блокер оказался 3-уровневой
цепочкой (typecheck guard/coercion + рантайм Interface_Value.data), плюс
2 попутно найденных бага (early-return без interface_cast для
безаргументных вариантов; instantiate_type's Enum-ветка не копировала
implemented_interfaces) и 1 отдельный (unify_types вместо == в operator
sugar для generic-enum'ов с нулевым-payload вариантом). Стадия 26
(`panos mod` — встроенный пакетный менеджер, go mod style) — ключевые
решения grilled (три раунда), touch-точки требуют Explore. Стадия 27
(`конст` — неизменяемые биндинги, binding-immutability, НЕ deep
immutability, + параметры функций/лямбд immutable по умолчанию) ✅
закрыта. Стадия 28 (generic-интерфейсы — недостающая под-фаза Стадии 7,
найдена как prerequisite Итерируемого) ✅ закрыта, оказалась проще
исходной оценки.
**Приоритет (grilled)**: 24/26/4/8 — следующие кандидаты, не
параллельно.

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

**Важно**: это НЕ настоящий FFI (см. Стадию 8 для того) — это статические
Odin-биндинги (`foreign import`, компилируются вместе с интерпретатором),
вручную завёрнутые в один конкретный panos-модуль `графика`, тем же
способом, что уже сделан `фс`/`ос`/`ввод_вывод`/`строки`/`сеть`
(`core/stdlib.odin` + `core/vm_io_native.odin`) — НИ ОДНОГО нового
языкового механизма не нужно, только больше host-Odin кода по
существующему шаблону. Ниже — конкретные точки для самостоятельной
реализации.

**Что**:
- Новый файл `core/raylib_bindings.odin` — `foreign import raylib
  "system:raylib"` + Odin-сигнатуры ~50 функций (InitWindow, DrawCircleV,
  GetMouseX/Y, Colors, Vector2 и т.п.), скопированные из `raylib.h`.
- Расширение panos-модуля стандартной библиотеки (`графика`) через ТЕ ЖЕ
  4 точки, что уже обслуживают `фс`/`ос`/`ввод_вывод`/`строки`/`сеть`
  (`core/stdlib.odin`):
  1. `is_builtin_module_name` (stdlib.odin:5-12) — добавить `name ==
     "графика"` в дизъюнкцию.
  2. `builtin_export_type` (stdlib.odin:62-127) — по одному `case
     "графика::имя_функции":` на каждую обёрнутую raylib-функцию,
     возвращает её panos-сигнатуру (`builtin_function_type_1/2/3` — уже
     есть хелперы на 1-3 параметра, для функций с бОльшим числом
     параметров понадобится `builtin_function_type_4`+ по аналогии).
  3. `ensure_builtin_module` (stdlib.odin:130-285) — новая ветка `else
     if name == "графика" { add_builtin_export(...) на каждую функцию }`.
  4. Рантайм-реализация — НОВЫЙ файл `core/vm_graphics_native.odin` (по
     аналогии с `core/vm_io_native.odin:101` — `call_builtin_io`),
     функция `call_builtin_graphics(vm, name, args) -> (result: Value,
     ok: bool, handled: bool)`, свитч по `"графика::..."`-именам, каждый
     case распаковывает `args[i]` в Odin-типы, зовёт raylib-биндинг,
     упаковывает результат обратно в `Value`. Подключить в `call_builtin`
     (vm.odin:753, там же, где уже подключён `call_builtin_io`) — ОДНОЙ
     строкой: `if result, ok, handled := call_builtin_graphics(vm, name,
     args); handled { return result, ok }`.
- **`#+build !js` на новых файлах** (raylib_bindings.odin,
  vm_graphics_native.odin) — обязательно, иначе WASM-сборка (демо-сайт)
  попытается слинковать raylib и упадёт. Тот же приём, что уже разделяет
  `vm_io_native.odin`/`vm_io_wasm.odin` — см. заголовок первого файла.
- Представление Vector2/Color: **не заводить новые Type_Kind** — Vector2
  уже один-в-один panos-тупл `(Число, Число)` (см. `docs/src/language/
  basic-types.md#тупы`), распаковывается в Odin-структуру прямо в
  `vm_graphics_native.odin`-обёртке (`v.(^Aggregate_Value).elements[0].
  (f64)` и т.п. — тот же паттерн, что для-in деструктуризация уже
  использует, compiler.odin `.Get_Property`). Color — либо тоже тупл
  `(Число, Число, Число, Число)` (RGBA), либо маленькая panos-структура
  `тип Цвет = структура r,g,b,a: Число конец`, объявленная В САМОЙ
  демо-программе (не требует host-кода вообще, если распаковка полей
  делается в graphics-обёртке через `.Get_Property` по индексу так же,
  как для тупла).
- Демо-программа: pong или snake в новом каталоге `demos/` (сейчас не
  существует — создать).

**Зачем**:
- Quick user-visible win, показывает язык живым.
- Проверяет FFI-концепцию (host-side static bindings) до investment в
  Стадию 8 (настоящий dynamic FFI — намного больше работы).

**Prerequisite**: нет содержательного. Технически удобнее делать ПОСЛЕ
знакомства с `core/stdlib.odin`/`core/vm_io_native.odin` — это готовый
шаблон, который эта стадия копирует практически без изменений.

**raylib не vendored в репозитории** (проверено — нет `external/raylib`,
нет упоминаний "raylib" вне ROADMAP/TASKS). Два варианта, решить перед
стартом:
- **Системный raylib** (`brew install raylib` на macOS, пакет
  дистрибутива на Linux) — `foreign import raylib "system:raylib"`
  подхватывает уже установленную библиотеку, тот же механизм, что
  `external/back/back_darwin.odin`'s `foreign import system
  "system:System.framework"` (проверено — Odin/этот тулчейн уже умеет
  `foreign import "system:..."`, ничего дополнительно настраивать не
  нужно). Минус — у КАЖДОГО, кто соберёт panos из исходников, должен
  быть системно установлен raylib, иначе линковка `panos`-бинарника
  упадёт (даже если демка ни разу не запускается) — обязательно завести
  build tag/флаг, чтобы `графика`-модуль был опциональной частью сборки,
  не тянул зависимость для всех.
- **Vendored raylib** (собрать из исходников в `external/raylib/`,
  аналогично `external/odin-http`) — воспроизводимая сборка без внешних
  системных зависимостей, но заметно больше работы (raylib сама на C,
  нужен C-компилятор в пайплайне сборки; см. также Стадию 26 про
  vendoring-конвенцию проекта — `external/` для стороннего кода, без
  `.git` внутри).

**Порядок работ**:
1. Решить: системный vs vendored raylib (см. выше) — сначала solo-грилинг
   самому себе, потом код.
2. `core/raylib_bindings.odin` (`#+build !js`) — `foreign import` +
   Odin-сигнатуры нужных функций (не обязательно все ~50 сразу — начать
   с минимума для pong: InitWindow/CloseWindow/WindowShouldClose/
   BeginDrawing/EndDrawing/ClearBackground/DrawRectangle/DrawCircleV/
   IsKeyDown/GetFrameTime).
3. `core/vm_graphics_native.odin` (`#+build !js`) — `call_builtin_
   graphics`, по одному `case` на функцию, marshalling Value↔Odin.
4. `core/stdlib.odin` — 4 точки выше (is_builtin_module_name/
   builtin_export_type/ensure_builtin_module + подключение в
   `call_builtin`, vm.odin:753).
5. `demos/pong.ps` — сама демо-программа на panos.
6. Проверка WASM-сборки НЕ ломается (`#+build !js` действительно исключил
   графику из wasm-таргета) — `just build-wasm` должен остаться зелёным.

**Checkpoint**: `./panos demos/pong.ps` — играбельный pong. Публикация
gif'а в README. `just build-wasm` не ломается (графика недоступна в
браузере, как и `фс`/`ос`/`сеть` сейчас).

**Effort**: 3 дня (плюс время на решение системный/vendored raylib выше).

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
- **Phase F** ✅ (см. заметку ниже, breaking change) — prelude cleanup:
  `Опция(T)` и `Результат(T, E)` переписаны как user-declared ADT в
  prelude-модуле. Убирает `Type_Kind.Option/.Result` special-case.

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

**Заметка по constraint generation/solver (сделано, ограниченный scope)**:
реализовано ПОСЛЕ Phase F, отдельно от generics-фаз (которые, как
показывают заметки ниже, обошлись без него на eager-unify). Полный
переход всего тайпчекера на generate-then-solve не сделан — Explore-
анализ насчитал 43 вызова `unify_types` в type_cheker.odin (3400+ строк),
большинство внутри eager bottom-up `infer_expr`/`check_expr`, где
тайпчекер не просто сверяет типы, а **делает структурные решения по уже
разрешённому типу** (какой метод резолвится на `.Массив` vs
`.Соответствие`, exhaustiveness `выбор` по `.Enum` и т.д.) — такие места
нельзя отложить на batch-solve без полного redesign на HM-стиль с
отложенной диспетчеризацией (недели работы, высокий риск регрессии по
всем тестам, ради нуля текущих функциональных проблем).

Вместо этого `Constraint`/`emit_constraint`/`solve_constraints`
(type_cheker.odin, рядом с `unify_types`) реализованы честно —
constraint'ы реально накапливаются в `Type_Ctx.pending_constraints` и
решаются отдельным батч-проходом — но применены ТОЛЬКО к **join-точкам**:
местам, где N уже ПОЛНОСТЬЮ выведенных (bottom-up) типов должны совпасть
друг с другом, и решение "что делать дальше" не зависит от
диспетчеризации внутри самого сравнения — `infer_if_expr` (тогда/иначе),
`infer_match_expr` (ветки `выбор`), `infer_array_expr`/`infer_map_expr`
(элементы/ключи/значения литералов). Раньше каждое из этих мест делало
`unify_types` сразу по мере обхода и репортило ошибку немедленно (но не
прерывало цикл — то есть эффективно уже собирало несколько диагностик за
проход). Теперь то же самое, но через явную инфраструктуру: батч
диагностирует ВСЕ несовпадающие элементы/ветки за один проход (проверено
живым тестом — `выбор` с двумя неправильными по-разному ветками репортит
ОБЕ ошибки, а не только первую). Побочный эффект: `infer_array_expr`/
`infer_map_expr` раньше инферили `elements[0]`/`entries[0]` ДВАЖДЫ (один
раз до цикла, второй раз внутри на i==0) — переписывание на "вывести всё,
затем сравнить" убрало это задвоение.

Остальные ~38 мест остаются на eager `unify_types` — см. обоснование
выше (структурная диспетчеризация по ходу обхода).

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
Generic-интерфейсы (`реализация ИнтерфейсX для Список`) были узко
отклонены здесь — снято позже, см. заметку ниже.

**Заметка по generic-интерфейсам (сделано после Phase F)**:
`реализация ИнтерфейсX для GenericТип` больше не отклоняется. Оказалось
НАМНОГО меньше работы, чем предполагала заметка Phase C ("сравнимо по
объёму с Phase E") — потому что сам интерфейс остаётся НЕ generic
(`Interface_Decl` по-прежнему без `[T]`): ни один метод контракта не
может ссылаться на T цели, значит `interface_method_types_match`
(сравнивает параметры/возврат мимо receiver'а) никогда не встречает
InferVar цели — контрактная проверка работает как для обычных конкретных
типов без единой правки. Вся реальная работа — убрать ранний `continue`
в ПРОХОД 3 (он пропускал не только контрактную проверку, но и
РЕГИСТРАЦИЮ методов — `реализация X для GenericТип` не работала вообще
никак, даже без интерфейса).

Попутно найдены и закрыты два независимых бага, оба вскрылись только при
попытке реально ИСПОЛЬЗОВАТЬ generic-тип через интерфейс полиморфно (не
просто объявить `реализация`):

1. **`implemented_interfaces` не переживал инстанциацию.**
   `instantiate_type`'s `.Struct`-ветка заводила для каждой инстанциации
   *новый пустой* `implemented_interfaces` (в отличие от `.methods`,
   который явно алиасится на карту шаблона) — `unify_types`'s
   interface-коэрция на инстанциированном `Коробка(Число)` всегда видела
   бы пустой список. Фикс: плоский снимок шаблона
   (`t2.implemented_interfaces = pruned.implemented_interfaces`) —
   безопасно, т.к. instantiate_type вызывается только из ПРОХОД 4,
   строго после того, как ПРОХОД 3 уже дописал шаблон целиком.

2. **Приведение к интерфейсу пропускалось для конструкторов/методов в
   аргументной позиции (баг, НЕ специфичный для generics).**
   `compile_expr`'s `case ^Call_Expr:` содержит СВОИ ранние `return`
   (Constructor_Struct/Method_Interface/Builtin/...), которые выходят из
   `compile_expr` целиком, минуя единственную проверку
   `ctx.tc.interface_casts` внизу функции. Живой баг: `показать(Коробка(5))`
   (конструктор структуры прямо в позиции аргумента интерфейсного
   параметра) падал в рантайме на "попытка вызвать интерфейсный метод у
   не-интерфейса", тогда как `пер к = Коробка(5); показать(к)` работал
   (`Ident_Expr` не имеет ранних `return` на этом пути). Подтверждено:
   баг воспроизводится и на СОВСЕМ не-generic структуре — просто ни один
   существующий e2e-тест не гонял интерфейс через конструктор-как-аргумент
   напрямую. Фикс: `maybe_emit_interface_cast` — общий helper, вызывается
   явно перед каждым таким early-return и один раз в общей развязке внизу.

**Всё ещё вне scope**: generic-интерфейсы САМИ ПО СЕБЕ (`тип
ИтераторX[T] = интерфейс ...`, где сигнатуры методов ссылаются на T) —
`Interface_Decl` по-прежнему не имеет `type_params`. Это отдельная,
более крупная фича (contract-matching между двумя независимо-generic
сторонами), не то же самое, что было отложено здесь.

**Заметка по Phase F (сделано, breaking change, сильно больше "1 день")**:
принят полный чистый вариант (обсуждено с пользователем) — `Есть`/`Нет`/
`Успех`/`Неудача` БОЛЬШЕ НЕ резолвятся голыми, только `Опция.Есть(...)`/
`Опция.Нет()`/`Результат.Успех(...)`/`Результат.Неудача(...)` (согласуется
со Стадией 18: конструктор варианта только через `Тип.Вариант`). Мигрированы
все существующие `.ps`-источники (`core/e2e_test.odin` — 55 сайтов,
`std/сеть/http.ps`, `test.ps`, `std/кодирование/toml.ps`).

Понадобился новый механизм **прелюдии**: `Опция`/`Результат` теперь
объявлены обычным panos-кодом (`core/prelude.odin`, embedded-строка
`PRELUDE_SOURCE`) и резолвятся/типизируются/компилируются РОВНО ОДИН РАЗ
на `Module_Graph` (`ensure_prelude`/`ensure_prelude_compiled`), их
экспорты (только `.Type`-kind символы, НЕ варианты — см. ниже) сливаются
напрямую в `module.scope.symbols` каждого модуля, т.к. `импорт` в panos
принципиально не сливает имена в scope (даёт только `алиас.Имя`).

Найдено и закрыто **четыре независимых бага**, ни один не был очевиден из
исходного плана:

1. **Merge вариантов вместе с типами.** `module.exports` содержит И типы,
   И их варианты (нужно для `Тип.Вариант` через чужой модуль). Наивный
   мерж ВСЕГО `prelude.exports` в scope делал `Есть`/`Успех` снова голо
   резолвящимися — ровно то, что breaking change должен был запретить.
   Фикс: в scope льются только символы `.kind == .Type`.

2. **"Map растёт из пустой — alias рвётся" (3 независимых места).** Odin-
   карта, скопированная в другую переменную ДО первой вставки (ещё без
   выделенного backing-массива), не гарантированно видит последующие
   вставки через ОРИГИНАЛ — если это единственный писатель. Проявилось
   как минимум трижды: (а) `graph.symbol_types` — резолв "фс"/"сеть" через
   `ensure_builtin_module` внутри `resolve_module` захватывал карту ДО
   того, как `ensure_prelude` успевала её наполнить → `Результат(...)` не
   резолвился как generic-тип ни для одного пользовательского модуля.
   Фикс: явный ресинк `ctx.symbol_types = graph.symbol_types` после
   `ensure_prelude` и в конце `resolve_module`. (б) `load_module_recursive`
   (module_loader.odin) звал `ensure_builtin_module` НА ЭТАПЕ СКАНИРОВАНИЯ
   импортов — до того, как `resolve_module`/`ensure_prelude` вообще
   запускались для графа — self-мемоизация `ensure_builtin_module`
   кэшировала "фс" с nil-типами навсегда. Фикс: `ensure_builtin_module`
   сама зовёт `ensure_prelude(graph)` защитно в начале. (в) `instantiate_
   type`'s `t2.methods = pruned.methods` — если инстанциация происходит
   ДО того, как `реализация` целевого типа обработана в ПРОХОД 3 (порядок
   деклараций в prelude.ps: `результат_или` в "реализация Опция" ссылается
   на `Результат(T,E)` РАНЬШЕ, чем "реализация Результат" объявляет свои
   методы) — копия `.methods` навсегда пустая. Фикс: диспетчер методов
   (`method_lookup`) читает `.methods` НЕ у инстанциации, а у ВЛАДЕЮЩЕГО
   ШАБЛОНА (`ctx.res.symbol_types[obj_type.generic_origin]`) — тот
   единственный объект, в который ПРОХОД 3 реально пишет.
   `decl_type_param_order`/`symbol_schemes` прелюдии для той же причины
   персистированы отдельно на `Module_Graph`/скопированы в `Resolver_Ctx`
   (переживают `resolve_program`, которая обнуляет `module_graph` после
   однократного резолва) и явно засеваются в КАЖДЫЙ новый `Type_Ctx`.

3. **Раскрытие сырого (не инстанцированного) generic-шаблона в unify.**
   `это: Опция`/`это: Результат` (bare, Phase E) резолвится в САМ
   разделяемый `^Type`-шаблон, общий на весь граф. Если тело метода
   вызывает ДРУГОЙ метод на `это` (`это.успех()` внутри "ошибка") или
   передаёт значение со структурно-шаблонным типом в конструктор ДРУГОГО
   generic-типа (`Опция.Есть(x)` внутри `Результат.опция()`, где `x`
   получен матчем на `это`) — `unify_types` СВЯЗЫВАЕТ T/E шаблона
   напрямую и НАВСЕГДА, ломая все последующие инстанциации этого типа во
   всей оставшейся программе. Фикс на двух уровнях: (а) новое поле
   `Type.is_decl_param` метит InferVar, созданный именно как ОБЪЯВЛЕННЫЙ
   параметр generic-декларации (не свежий per-call); `bind_infer_var`
   считает unify успешным, но НЕ пишет `.binding` на такой InferVar —
   структурная совместимость гарантирована по построению (значение и
   так пришло от T), фиксировать её незачем и опасно. (б) диспетчер
   методов дополнительно переинстанцирует `obj_type` через `instantiate_
   scheme`, если это сырой шаблон — чище семантически, хотя (а) уже
   закрывает корень проблемы.

4. **Ослабленные сигнатуры `заменить_значение`/`заменить_ошибку`.**
   Старый VM-диспетчер позволял им МЕНЯТЬ тип (`Результат(Число,...)`.
   `заменить_значение("текст")` → `Результат(Строка,...)`) — bare `это:
   Результат, новое: T` в prelude.ps этого не выражает (`T` жёстко = T
   владельца). Обе получили собственный type-параметр метода
   (`заменить_значение[U](это: Результат, новое: U) -> Результат(U, E)`,
   аналогично `результат_или[E]`).

Побочный эффект уборки: `Результат.ожидать` для НЕ-Ошибка `E` больше не
может (и не пытается) авто-дописывать `error.сообщение` в паническое
сообщение — это было спецкейсом старого диспетчера конкретно под
`Error_Value`, не обобщается на произвольный generic `E`.

**Порядок работ**:
1. Phase A ✅: implicit rank-1 (1 день).
2. Phase B ✅: явные generic functions + syntax `[T]` (2 дня).
3. Phase C ✅: generic structs (интерфейсы отложены, 2 дня).
4. Phase D ✅: generic ADT + 3 связанных бага (identity unify для Enum,
   кэш-ключ порядка полей, циклические типы) — сильно больше 1 дня.
5. Phase E ✅: impl over generic (методы; интерфейсы отложены, 2-3 дня).
6. Phase F ✅: prelude cleanup + breaking change — сильно больше 1 дня
   (механизм прелюдии с нуля + 4 независимых бага, см. заметку выше).
7. E2E тесты + docs ✅: E2E-покрытие набралось инкрементально за Phase
   A-F (test-as-you-go — каждая фаза добавляла тесты вместе с кодом,
   часть багов Phase D/F найдена именно живыми тестами, не ревью) —
   отдельного финального прохода не потребовалось. Docs: новый раздел
   `docs/language.md#дженерики` (generic функции/структуры/ADT/методы,
   ограничения), `AGENTS.md` дополнен кратким аналогом. `## Опция`/
   `## Результат` в обоих файлах и `выбор`-пример обновлены под Phase F
   breaking change (голые конструкторы → `Опция.Есть(...)`/`Результат.
   Успех(...)`; `выбор`-шаблоны остаются валидны и без квалификации —
   отдельно оговорено, т.к. это НЕ то же ограничение, что у конструктора-
   выражения). Все новые примеры в доках проверены живым прогоном.

**Checkpoint**: `функ первый[T](xs: Массив(T)) -> Опция(T)` работает.
Опция и Результат — обычные user-declared ADT. Type checker без
special-case для них.

**Effort**: ~11-14 дней.

---

### Стадия 8 — FFI фаза B: dynamic (3-4 недели)

**Важно, перед стартом**: это самая крупная и наименее проработанная
стадия во всём ROADMAP — исходный план был чисто аспирационным списком
фич без единой проверки против реального кода. Ниже — исправленные факты
и конкретные точки входа в текущий код (все перепроверены вручную,
16.07.2026), но САМИ архитектурные решения (см. "Не решено" ниже) ещё не
приняты — это первое, что нужно сделать самостоятельно, скорее в стиле
grilling-сессий, которыми делались Стадии 24/29-31 (см. их ROADMAP-записи
как образец формата: список вопросов, явное решение по каждому, потом
код).

**Что** (список функций не изменился по существу, детали ниже):
- Грамматика `внешний "libc" функ open(путь: КСтрока, флаги: Число_32) -> Число_32`.
- FFI-типы: `Число_32`, `КСтрока`, `Указатель(T)`, `ff_структура` (см. ниже
  — статус каждого как "новый Type_Kind" vs "чисто marshalling-аннотация"
  не решён).
- Настоящий dynamic FFI (сигнатура C-функции описывается panos-исходником
  на этапе резолва, а не Odin-кодом на этапе компиляции интерпретатора —
  этим отличается от Стадии 4, где каждая обёрнутая функция требует
  ручного host-кода).
- Marshalling: primitives, strings, structs-by-value.
- Opcode `Call_Foreign` + VM handler.
- Callback'и через `ffi_closure` (runtime-generated trampolines).
- Memory ownership аннотации: `(владеет_я)` / `(владеет_C)`.
- SIGSEGV recovery: попытка вернуть `Результат.Неудача(Ошибка(...))`
  вместо падения всего интерпретатора.
- (Опционально, после MVP) Постепенная миграция части stdlib (`фс`, `ос`)
  с host-Odin реализации на panos+FFI поверх libc.

**Зачем**:
- User-space обёртки любых C-либ без host-recompile — Стадия 4 даёт
  только ОДНУ конкретную либу (raylib), FFI-B даёт СПОСОБ подключить
  любую.
- Профессиональная планка (LuaJIT FFI-level).

**Исправленный prerequisite** (оригинальная формулировка была
фактически неверна — проверено вручную): "Стадия 1 (GC finalizers
обязательны)" подразумевает, что Стадия 1 построила ОБЩИЙ механизм
регистрации финализаторов. **Это не так** — такого механизма нет и
никогда не было. То, что реально есть (`core/gc.odin`, `pool_release`,
~line 417-444): у `File_Value`/`Socket_Value` ЖЁСТКО ЗАШИТЫЙ в
`pool_release`'s `case ^File_Value:`/`case ^Socket_Value:` вызов
`close_file_value`/`close_socket_value` — запускается при sweep'е, если
объект стал недостижим, а `.закрыть()` не был вызван явно (комментарий
в коде прямо называет это "finalizer-принципом"). Это **не общая
инфраструктура**, а два отдельных hardcoded case'а. Хорошая новость:
для `Указатель(T)`/`ff_структура` с `(владеет_я)` не нужно строить
никакой новый generic-механизм — нужен ТРЕТИЙ такой же hardcoded case
(`pool_release`'s `case ^Pointer_Value: if val.owned { <вызов
деструктора/free> }`), точно по образцу двух существующих. Реальный
prerequisite — только Стадия 6 (уже ✅, `Call_Info`/`Call_Kind` для
диспетчеризации нового вида вызова).

**Не решено — вопросы для самостоятельного грилинга перед кодом**:
1. **Загрузка библиотеки: `foreign import` (compile-time) vs `core:
   dynlib` (runtime `dlopen`/`dlsym`)?** Это НЕ один и тот же вопрос, что
   "нужен ли libffi" — это ДВЕ разные проблемы:
   - **Поиск и открытие библиотеки + получение указателя на функцию по
     имени** — Odin's `foreign import "system:libc"` требует, чтобы ИМЯ
     и СИГНАТУРА функции были известны Odin-компилятору НА ЭТАПЕ СБОРКИ
     panos. Но `внешний "libc" функ open(...)` — это panos-исходник,
     читаемый интерпретатором В РАНТАЙМЕ; интерпретатор скомпилирован
     ОДИН РАЗ и не может заранее знать все библиотеки/функции, которые
     когда-либо укажет пользовательский `.ps`-файл. Значит нужна
     ДЕЙСТВИТЕЛЬНО динамическая загрузка — `core:dynlib` (Odin's
     собственный std-пакет, `dynlib.load_library("libc.so")` +
     `dynlib.symbol_address(lib, "open")`, POSIX `dlopen`/`dlsym` под
     капотом) — НЕ `foreign import` (та статическая, для Стадии 4 годится,
     для Стадии 8 — нет).
   - **Вызов функции по указателю с сигнатурой, известной только в
     рантайме** — вот тут нужен libffi (`ffi_prep_cif` + `ffi_call`):
     Odin, как и большинство статически скомпилированных языков, не умеет
     вызвать `rawptr` как функцию с ПРОИЗВОЛЬНОЙ, заранее неизвестной
     сигнатурой без низкоуровневой помощи — libffi предоставляет именно
     это (marshalling аргументов в нужный по ABI формат перед вызовом).
   - Итого: `core:dynlib` решает "найти функцию", libffi решает
     "вызвать функцию с рантайм-сигнатурой" — обе части нужны, не
     взаимозаменяемы.
2. **Статическая линковка libffi vs системная.** Оригинальный план
   говорил "static-linked libffi в бинарник panos" — это означает C
   toolchain в build-пайплайне (собрать libffi из исходников или слинковать
   `.a`), заметно увеличивает сложность сборки. Альтернатива — линковаться
   с системным `libffi` (`foreign import "system:ffi"`, обычно уже стоит
   в системе или ставится пакетным менеджером — на macOS есть в составе
   Xcode CLT, на большинстве Linux-дистрибутивов пакет `libffi-dev`/
   `libffi`) — тот же trade-off воспроизводимость/простота, что и у
   raylib в Стадии 4. **libffi НЕ vendored в репозитории** (проверено —
   нет упоминаний нигде, кроме ROADMAP/TASKS) — решить перед стартом.
3. **`Число_32`/`Число_64`/аналоги — новый `Type_Kind` или просто
   marshalling-аннотация в `внешний`-сигнатуре?** panos's `Число` —
   ВСЕГДА `f64` (см. `docs/src/language/basic-types.md#базовые-типы`,
   "единственный числовой тип"), это принципиальное упрощение языка.
   Два пути:
   - (a) `Число_32` и т.п. — НЕ настоящие panos-типы, а просто СИНТАКСИС
     внутри `внешний`-декларации, говорящий компилятору, как упаковать/
     распаковать обычное `Число` на границе FFI-вызова (сам параметр
     типизируется как `Число` для остального языка, `Число_32` — только
     метаданные для marshalling-кода). Минимальное изменение — не трогает
     `Type_Kind`/unification вообще.
   - (b) `Число_32` — настоящий отдельный `Type_Kind`, видимый
     тайпчекеру — большая работа (unification-правила, coercion с
     обычным `Число`), но точнее ловит ошибки (`Число_64`-параметр,
     которому передали то, что реально требует `Число_32`, диагностика
     на месте вызова, а не только по факту усечения при marshalling).
   Рекомендация (не обязательна к принятию, но снижает объём работы):
   начать с (a), эскалировать к (b), если diagnostics окажутся
   недостаточно понятными на практике.
4. **`ff_структура` — новое объявление или переиспользование обычной
   `структура`?** C ABI требует явный контроль layout (field order,
   size, alignment/padding) — обычная panos `структура` (реализована как
   `Aggregate_Value.elements: [dynamic]Value`, вообще без C-совместимого
   memory layout — это управляемый GC-объект, не raw memory blob) для
   этого не подходит напрямую. Вероятно нужен НОВЫЙ вид декларации
   (`ff_структура X = ...`) со своим представлением в рантайме (не
   `Aggregate_Value` — что-то вроде byte-buffer с полями, размещёнными по
   вычисленным C-offset'ам) — это отдельная, не маленькая под-задача,
   ближе по духу к `Указатель(T)` (см. ниже), чем к обычным структурам.
5. **Платформенный охват SIGSEGV-recovery.** POSIX (Linux/macOS) —
   `sigaction`/`sigaltstack` (Odin's `core:sys/unix` или `core:sys/posix`);
   Windows — принципиально другой механизм (SEH/vectored exception
   handlers), НЕ переиспользуется. Решить, входит ли Windows-охват в
   scope v1, или это Unix-only фича на первое время (пример
   уже-принятого асимметричного решения в проекте: TLS/сеть — см. Стадию
   26, "TLS-пробел в core:net — норма для системных языков").

**Конкретные точки в текущем коде (для частей, которые НЕ зависят от
решений выше)**:
- **Грамматика `внешний`**: новый `TokenKind` (`core/token.odin`,
  список — см. `.Spawn`, добавленный тем же способом в Стадии 24) +
  запись в `lookup_ident` (`core/lexer.odin`, тот же свитч, что уже
  распознаёт "функ"/"тип"/"импорт" и т.п.) + новый вариант `^Foreign_Decl`
  в `Decls` (`core/parser.odin:143-151`, сейчас 7 членов: Import_Decl/
  Function_Decl/Struct_Decl/Impl_Decl/Interface_Decl/Enum_Decl/
  Error_Decl) + `parse_foreign_decl` + новая ветка `else if tok_kind ==
  .Foreign` в `parse_program`'s top-level dispatch (`core/parser.odin:
  600-688`, вставить ПЕРЕД catch-all `else` на line 676 — та же точка,
  где добавлялась бы любая другая новая top-level форма).
- **`Указатель(T)` как опаковый generic-тип**: точный прецедент —
  `Процесс(T)` из Стадии 24 (`core/type_cheker.odin`, `Type_Kind.Process`,
  `new_process_type`, третья ветка в `Type_Generic`-цепочке
  `resolve_type_node`, рядом с `Массив`/`Соответствие`) — T хранится
  напрямую в `element_type`, БЕЗ `Type_Scheme`/`instantiate_scheme`
  (Struct/Enum generic-механизм). `Указатель(T)` — тот же приём, четвёртая
  ветка в той же цепочке.
- **`Pointer_Value` как новый Value-вариант**: точный прецедент —
  `File_Value`/`Socket_Value`/`Process_Value` (все три — `struct {header:
  GC_Header; ...}`, добавлены в `Value :: union {...}`, `core/
  compiler.odin`). Новый тип требует ровно те же 5 точек в
  `core/gc.odin`: `get_header` (exhaustive switch), `mark_value`
  (exhaustive switch), `value_size` (exhaustive switch), `pool_release`
  (exhaustive switch — СЮДА же владение `(владеет_я)`/`(владеет_C)`, см.
  выше про finalizer-паттерн), `gc_new`'s `when T == ...`-диспетчер.
  Odin's exhaustive-switch проверка на компиляции САМА укажет все 5 мест
  как ошибки компиляции сразу после добавления `^Pointer_Value` в `Value`
  — тот же метод "расширил union → компилятор перечислил все точки
  правки", которым велась вся работа над Стадией 24 в этой сессии.
- **Типизация `внешний`-декларации**: НЕ похожа на `Type_Generic`-путь
  выше — `внешний функ ...` регистрирует НОВЫЙ СИМВОЛ функции (не тип).
  Ближайший прецедент — как `install_standard_symbols`/`is_builtin_
  module_name`/`builtin_export_type` (`core/stdlib.odin`) регистрируют
  типы для `фс.прочитать` и т.п. (статическая таблица "имя → тип
  функции", читаемая типчекером при резолве вызова) — но там таблица
  РУЧНАЯ (пишется в Odin-коде заранее). Для `внешний` таблица должна
  строиться ДИНАМИЧЕСКИ, во время резолва КАЖДОЙ КОНКРЕТНОЙ
  `.ps`-программы (из самой `внешний`-декларации, распарсенной как
  `Foreign_Decl`), не заранее в Odin-коде — принципиальное отличие от
  `stdlib.odin`'s подхода, ближе по духу к тому, как резолвятся обычные
  `Function_Decl` (сигнатура строится из AST на ПРОХОД 2, см.
  `type_cheker.odin`'s `case ^Function_Decl:` в `typecheck_program`).
- **`Call_Foreign` opcode**: новый член в `Opcode :: enum u8 {...}`
  (`core/compiler.odin`) — операнды по образцу `.Call_Builtin` (имя как
  индекс константы + arg_count) или `.Call` (function pointer на
  стеке) — выбор зависит от того, как решится "где хранится
  подготовленный `ffi_cif` + указатель на функцию" (вероятно новый
  Value-вариант или поле на `Foreign_Decl`'s скомпилированном
  представлении, а не сырая строка-имя, раз сигнатура строится один раз
  при резолве, не при каждом вызове).
- **Вендоринг libffi (если решение по вопросу 2 — vendored, не
  системный)**: конвенция проекта уже задана Стадией 26 и существующими
  `external/back`/`external/odin-http`/`external/toml_parser` — тот же
  `external/`, без `.git` внутри, plain tracked files.

**Порядок работ** (пересмотрен под вышеописанное — количество дней не
переоценивалось заново, исходные оценки могли быть оптимистичны теперь,
когда видно реальный объём "Не решено"):
1. Грилинг вопросов 1-5 выше — сначала архитектурные решения, потом код
   (как Стадии 24/29-31).
2. Грамматика `внешний` (TokenKind/lexer/Decls/parser) (2 дня).
3. `core:dynlib`-based загрузка библиотек + получение указателя функции
   (0.5-1 день).
4. libffi bindings в Odin (`foreign import`, статически или системно —
   по решению вопроса 2) (0.5 дня).
5. Type descriptor builder (panos-тип из `внешний`-сигнатуры → `ffi_type`)
   (2 дня).
6. Primitive marshalling (1 день).
7. `Указатель(T)`/`Pointer_Value` + владение через `pool_release`
   (по образцу File/Socket, см. выше) (1-2 дня).
8. String marshalling (КСтрока ↔ Panos_String, кто владеет буфером) (1
   день).
9. `ff_структура` marshalling (зависит от решения вопроса 4 — вероятно
   самая объёмная часть) (2-3 дня).
10. `Call_Foreign` opcode + VM handler (1 день).
11. Тесты через libc (printf/getpid/open) (1 день).
12. SIGSEGV recovery (в решённом на вопросе 5 объёме) (1-2 дня).
13. Callback'и через `ffi_closure` (3-4 дня, самая сложная часть —
    runtime-generated trampolines).
14. (Опционально) обёртка raylib на panos-стороне взамен Стадии 4's
    host-bindings (2 дня).
15. (Опционально) миграция `фс`/`ос` на panos+FFI поверх libc (2 дня).
16. Docs (1 день) — новая глава `docs/src/language/ffi.md` по образцу
    `docs/src/language/networking.md`/`file-io.md`.

**Checkpoint**: `внешний "libc" функ getpid() -> Число_32` вызывается из
`.ps`-файла и возвращает реальный PID процесса — минимальный сквозной
тест дальше libffi/dynlib связки работают. Демо-программы на raylib через
FFI (не host-bindings Стадии 4) — опционально, после MVP.

**Effort**: изначальная оценка ~15-20 дней предполагала прямую
реализацию по уже готовому плану; с учётом непринятых решений выше
(особенно вопросы 1, 2, 4) реалистичнее закладывать доп. время на
грилинг + возможную переработку по ходу — как и у Стадии 24 в этой
сессии, которая тоже была "дважды пересмотрена" после первого раунда.

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

### Стадии 10-21 — вне очереди (не было в исходном плане) ✅

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
- **Стадия 18** — Варианты перечислений убраны из глобального namespace
  модуля: `Есть`/`Нет` и т.п. резолвятся только квалифицированно
  (`Опция.Есть(...)`), не голым именем.
- **Стадия 19** — `Пусто`-функция не обязана заканчиваться `Пусто`-
  выражением — последнее значение молча отбрасывается, а не требует
  явного приведения.
- **Стадия 20** — `module_loader.odin` error-recovery: последний
  оставшийся `fmt.panicf`-путь пайплайна (file-not-found/circular import)
  переведён на diagnostics — LSP переставал крашиться целиком на плохом
  импорте.
- **Стадия 21** — Диагностика: `для x в` напрямую на `Соответствие` (без
  `.записи()`) теперь даёт понятное сообщение вместо generic type-error.

---

### Стадия 22 — Сравниваемое (Ord) и Равнозначное (Eq): operator sugar ✅

**Что**: prelude-интерфейсы `Сравниваемое`/`Равнозначное`, дающие
пользовательским структурам `<`/`>`/`<=`/`>=` (через `реализация
Сравниваемое для Тип`, метод `сравнить(другое) -> Число`, конвенция
-1/0/1) и опционально переопределяемое `==`/`!=` (через `реализация
Равнозначное для Тип`, метод `равно(другое) -> Булево`). Sugar — типизация
резолвит `а < б` в вызов метода на этапе typecheck/compile, не новый
рантайм-механизм.

**Зачем**: `<`/`>`/`<=`/`>=` сейчас хардкод, принимают только `Число` —
для структур сравнение недоступно вообще (`std/коллекции.ps`'s
`отсортировать` поэтому берёт явный компаратор как костыль). `==`/`!=`
уже работают структурно на любых типах (`value_equals`, vm.odin) —
`Равнозначное` даёт opt-in override для типов, которым дефолт не подходит
(referencing/ID-based equality и т.п.), не required-impl.

**Пререквизит** (общая возможность интерфейсов, не хак под эту фичу):
Self-тип в сигнатурах методов интерфейса. `interface_method_types_match`
(type_cheker.odin:1237) сейчас требует точного совпадения типа
параметра между объявлением интерфейса и impl — параметр, объявленный
как тип самого интерфейса, должен для ЛЮБОГО impl матчиться на
конкретный реализующий тип (а не оставаться интерфейсным), иначе
`другое` внутри метода не даёт доступа к полям.

**Осознанно вне scope v1**: generic-функции. Тело generic-функции
типизируется РОВНО ОДИН РАЗ, абстрактно (type-параметр — голая InferVar,
не подставляется заново на каждую инстанциацию) — `T < T` внутри `функ
f[T](...)` не может резолвить "реализует ли T Сравниваемое" без
trait-bound синтаксиса (`T: Сравниваемое`), которого в языке нет. Только
конкретные типы на конкретных call site'ах; generic-сортировка остаётся
на явном компараторе, как сейчас.

**Prerequisite**: нет (независимо от других стадий; использует уже
готовую инфраструктуру интерфейсов из Стадии 7).

**Порядок работ**:
1. Self-тип: фикс в проверке контракта `реализация X для Y`
   (type_cheker.odin ~1608-1625) — если ожидаемый тип параметра
   указательно равен типу самого интерфейса, сравнивать фактический
   параметр с конкретным целевым типом, не структурно (1 день).
2. Prelude: `Сравниваемое`/`Равнозначное` в `PRELUDE_SOURCE`
   (core/prelude.odin) + `prelude_comparable_sym`/`prelude_equatable_sym`
   на `Module_Graph`/`Resolver_Ctx`, по образцу
   `prelude_option_sym`/`prelude_result_sym` (0.5 дня).
3. Typechecker: резолв sugar в кейсах `.Less`/`.Greater`/`.LessEqual`/
   `.GreaterEqual`/`.Equal`/`.NotEqual` (type_cheker.odin ~2577-2600) —
   лукап `implemented_interfaces` + `method_lookup`, запись в
   существующий `ctx.call_infos` (0.5 дня). **Grilled**: точное
   сообщение для несовместимых операндов — если `left_t` реализует
   Сравниваемое, но `right_t != left_t` (напр. `Точка < Линия`, оба
   свои Сравниваемое, но не друг с другом, или `Точка < 5`) — отдельная
   diagnostic-ветка "тип 'Точка' реализует Сравниваемое, но не с типом
   'Линия'/'Число'", НЕ старое "ожидает два числа" (которое вводило бы
   в заблуждение — `Точка` вообще-то сравнимая, просто не с этим
   операндом). Заложено сразу, не отложено на потом.
4. Compiler: новая ветка в `^Binary_Expr`-кейсе (compiler.odin
   ~501-565) — переиспользует существующий `.Method_Struct`-кодоген
   (push fn-константа, компиляция операндов, `.Call`), плюс
   пост-обработка (сравнение с 0 для Ord, опциональный `.Negate` для
   `!=`) (0.5-1 день).
5. E2E-тесты + негативные кейсы (структура без impl — понятная
   diagnostic, не молчаливый фоллбэк) (0.5 дня).

**Checkpoint**: структура с `реализация Сравниваемое для Точка`
сортируется через `<` напрямую, без ручного компаратора. Структура с
`реализация Равнозначное` использует свой `равно` в `==`; структура без неё
— прежнее структурное сравнение, без регрессии.

**Effort**: ~2-3 дня.

**Полный технический план** (детальные file:line-цитаты, найденные при
исследовании нюансы, порядок вставки полей): изначально составлен в
`/Users/gaidar/.claude/plans/abstract-napping-valiant.md` (session-local
plan-mode файл, не в репозитории) — этот раздел ROADMAP.md его
консолидирует, отдельного файла в репозитории не заводим.

**Заметка (сделано)**: реализовано точно по плану, все 5 шагов Порядка
работ без отклонений — `interface_method_types_match` принял
`iface_type`/`target_type` параметры (Self-маркер = указательное
равенство с `iface_type`), `implements_prelude_interface` helper (новый,
не было в плане явно, но тривиальный — номинальная проверка через
`implemented_interfaces`) переиспользован для обоих Ord/Eq кейсов.
89/89 тестов (было 82, +6 новых для Ord/Eq: операторы, Self-тип
field-access, негативный кейс без impl, точное mismatch-сообщение,
Equatable-override, регрессия структурного `==` без impl; +1 отдельно
для найденного и исправленного бага, см. ниже). `odin build .`/`./lsp`/
wasm — все три цели чисто.

**Побочная находка и фикс (НЕ баг Стадии 22, предсуществующий, но
исправлен в её же сессии)**: `кол.отсортировать`/`кол.отфильтровать`
(std/коллекции.ps) с T=структура ломали generic-инференс —
`результат[0].x` давало "попытка получить поле у не-структуры (тип:
?N)". Воспроизведено И БЕЗ единого упоминания Ord/Eq (`a.x < b.x`, только
числа внутри структуры) — не связано со Стадией 22. Root cause: вызов
ЭКСПОРТИРОВАННОЙ generic-функции ЧЕРЕЗ АЛИАС МОДУЛЯ (`алиас.функция(...)`)
не инстанцировал T заново — `infer_call_expr`'s `Property_Expr`-ветка
использовала общий, шаблонный `export_type` напрямую, в отличие от
same-file вызова (`infer_ident_expr`, инстанцирует через
`symbol_schemes` уже давно). Причина расхождения — `Type_Ctx.symbol_schemes`
не шарится между модулями (в отличие от `symbol_types`, растущего как
единая map через весь граф): каждый `new_type_ctx` заводил СВОЮ пустую
copy, кроме явно прокинутых prelude-схем. Фикс: `Module_Graph.
symbol_schemes` — накапливается в `resolve_and_typecheck_all`
(module_loader.odin) после typecheck каждого модуля, раздаётся
следующим через `new_type_ctx` (тот же паттерн, что уже был у
`prelude_symbol_schemes`, просто для ВСЕХ модулей, не только прелюдии).
`infer_call_expr` инстанцирует схему через уже существующий
`instantiate_scheme`, если она есть. Регрессионный e2e-тест
(`fixtures/generic_cross_module_fixture_*.ps`, `run_module_file` — баг
специфичен именно межмодульному вызову, single-file inline-pipeline его
не воспроизводит). Оригинальный Checkpoint-сценарий "сортируется через
`<` напрямую" теперь ТОЖЕ подтверждён живьём через `отсортировать`.

---

### Стадия 23 (кандидаты, не исследовано) — дальнейшие type classes

**Статус**: список кандидатов из обсуждения, НЕ прошедший то же
исследование file:line-уровня, что Стадия 22 (там — два Explore-агента
по interface-диспатчу и generic-мономорфизации, потом AskUserQuestion по
развилкам). Каждый пункт ниже нужно так же прогнать через
plan-mode/Explore ПЕРЕД тем, как писать Порядок работ с конкретными
file:line — до этого это гипотезы уровня "какой тир сложности", не
готовый план.

- **Печатаемое (Show/Display)** ✅ — реализована. Investigation вскрыла,
  что исходная гипотеза плана была НЕВЕРНА: `вывод.печать`/строковая
  интерполяция НЕ форматируют значения авто-магически "по умолчанию"
  (`%v`-дампа не было вообще) — `ввод_вывод::печать`/`строка` требовали
  Строка-аргумент СТРОГО (typecheck: `builtin_function_type_1(TY_STRING,
  ...)`, рантайм: `expect_string_arg` паникует на любом non-string), а
  строковой интерполяции в языке нет вовсе. Grilled-развилка: сделать
  `печать`/`строка` полиморфными (принимают ЛЮБОЙ Value) — выбрано (не
  заводить отдельный явный конвертер). Механизм ИНОЙ, чем operator-sugar
  Стадии 22/23: т.к. Aggregate_Value (struct) не хранит RTTI в рантайме
  (см. заметку у самой структуры, compiler.odin) — метод `.вСтроку()`
  ОБЯЗАН резолвиться на CALL SITE (typecheck-время), не рантаймом,
  ровно как Ord/Eq/Арифметика. Реализация: новый `Call_Kind.Print_Value`
  — спецкейс в `infer_call_expr` (typecheck) ДО обычной unification
  параметров для `ввод_вывод::печать`/`строка`: если arg — struct с
  `implements_prelude_interface(Печатаемое)`, компилятор вставляет вызов
  `.вСтроку()` ПЕРЕД реальным builtin'ом (push fn, receiver, `.Call 1`,
  результат → `.Call_Builtin`); иначе — рантайм сам форматирует ЛЮБОЙ
  Value через новый `value_to_display_string` (vm.odin, зеркалит
  `value_equals` по покрываемым вариантам: f64/bool/Panos_String/
  Error_Value/Option_Value/Result_Value/Interface_Value/Compiled_Function/
  File_Value/Socket_Value/Variant_Value/Aggregate_Value/Array_Value/
  Map_Value, с visited-set защитой от циклов). Известное ограничение (не
  баг): structural dump для struct БЕЗ Печатаемое — позиционный, БЕЗ
  имени типа/полей (`(3, 4)`, не `Точка(x: 3, y: 4)`) — рантайм
  действительно не хранит имя типа для Aggregate_Value; Variant_Value
  хранит `type_name`, но не имя конкретного варианта (только tag_index).
  3 новых e2e-теста с РЕАЛЬНОЙ проверкой напечатанного текста (новый
  `run_code_capture_stdout` — временно подменяет `os.stdout` на файл,
  т.к. `fmt.print` перечитывает `os.stdout` при каждом вызове, не
  кэширует writer). `odin test ./core` — 96/96; native/lsp/wasm чисто.
- **Арифметика** (`+`/`-`/`*`/`/` overload) ✅ — реализована. Grilled-
  развилка (один интерфейс на все 4 vs раздельно): выбрано **4
  раздельных интерфейса** (Складываемое/Вычитаемое/Умножаемое/Делимое,
  методы сложить/вычесть/умножить/разделить) — в отличие от Ord (где
  сравнить даёт ВСЕ 4 сравнения бесплатно, это ОДНА способность), +-*/
  математически независимы (тип может иметь + без / — вектор без
  деления на вектор), как в Rust Add/Sub/Mul/Div. Найдено при
  реализации: Self-фикс Стадии 22 (`interface_method_types_match`,
  type_cheker.odin) покрывал только Self-ПАРАМЕТР, не Self-ВОЗВРАТ —
  сравнить/равно всегда возвращают примитив (Число/Булево), а
  сложить/вычесть/... возвращают САМ Self-тип (`Вектор + Вектор ->
  Вектор`), так что `expected.return_type == iface_type` тоже требует
  Self-подстановку (`actual.return_type == target_type`) — фикс
  расширен, общий для любого будущего интерфейса с Self-возвратом.
  `.Plus` (Число+Число/Строка+Строка) не тронут — sugar-ветка добавлена
  ПОСЛЕ обеих хардкод-проверок; `.Minus/.Star/.Slash` вынесены в общий
  `infer_arithmetic_op` (был единый case, теперь 3 отдельных с разным
  iface_sym/method_name). Codegen — реюз `.Method_Struct`-паттерна
  Стадии 22 (push fn, receiver, arg, `.Call 2`), без пост-обработки —
  результат уже Self. 4 новых e2e-теста (все 4 операции на одной
  структуре + 3 негативных: обычный numeric-путь не сломан, precise
  diagnostic при разнотипном сложении, вычесть не путается со
  сложить). `odin test ./core` — 93/93.
- ~~По-умолчанию (Default)~~ — ВЫБРОШЕНО из плана. Мотивация была
  спекулятивной: `Массив.заполнить(N)` (единственный названный
  потребитель) не существует нигде в stdlib — проверено (`grep` по
  `std/*.ps` и `core/*.odin`), реального consumer'а нет. Если
  когда-нибудь появится конкретный use case — заводить заново с
  реальной мотивацией, не как "раз уж мы тут".
- **Копируемое (Clone)** ✅ — реализована. Присваивание (`=`) НЕ
  трогается (отдельно обсуждено и явно отклонено — авто-копирование на
  `=` меняло бы универсальную семантику языка, слишком большой и
  рискованный scope; reference semantics остаётся базовой моделью
  языка осознанно, обсуждалось отдельно). `.клонировать()` — обычный
  ПРЯМОЙ вызов метода, НЕ operator sugar (в отличие от Сравниваемое/
  Равнозначное/Арифметики) — оказался БЕСПЛАТНЫМ: работает через уже
  существующий generic interface-dispatch (Стадия 6) без единой строчки
  нового кода в type_cheker.odin/compiler.odin, подтверждено эмпирически
  ДО реализации (временный тест с самодельным интерфейсом). Self-возврат
  (`клонировать() -> Копируемое`, ноль явных параметров помимо receiver)
  уже покрыт фиксом `interface_method_types_match`, добавленным для
  Арифметики (return_type-Self-подстановка) — валидирует, что тот фикс
  общий, не завязан именно на бинарные операторы. "Глубокая копия" — НЕ
  auto-derive (как и у всех прочих интерфейсов, тело метода пишется
  руками): для настоящей глубины тело обязано САМО рекурсивно звать
  `.клонировать()` на вложенных struct-полях — язык это не проверяет,
  задокументировано как осознанный design (не derive-макрос). Заведён
  `prelude_copyable_sym` (не используется typecheck/compiler-кодом
  самого Копируемое, но нужен будущей Стадии 24 — copy-on-send должен
  отличать "есть кастомный `.клонировать()`" от дефолтного reflective-
  копирования). 2 e2e-теста (плоская структура — независимая копия;
  вложенная структура — корректная рекурсия в теле клона).
  `odin test ./core` — 103/103; native/lsp/wasm чисто.
- ~~Хешируемое (Hash)~~ — ВЫБРОШЕНО из плана. Investigation (тот же
  паттерн, что По-умолчанию/Печатаемое — премиса плана оказалась
  неверна): `Соответствие` в рантайме — НЕ хеш-таблица, никакого
  "рантайм-хеша карт" не существует. `Map_Value.entries` (compiler.odin)
  — плоский `[dynamic]Map_Entry_Value`, `map_find_index` (vm.odin:295)
  — линейный перебор с `value_equals` на каждой записи. Единственное,
  что реально блокирует struct/enum-ключи — typecheck-уровневый
  whitelist `is_valid_map_key_type` (type_cheker.odin:166,
  `.Number || .Bool || .String`) — `value_equals` УЖЕ умеет рекурсивно
  сравнивать структуры/перечисления с защитой от циклов (structural `==`
  этой же сессии). Интерфейс "Хешируемое" (протокол вычисления hash-кода)
  без реальной хеш-таблицы под ним не имеет смысла — если понадобятся
  struct-ключи, это вопрос ОДНОЙ строки (relax whitelist), не отдельного
  интерфейса; если понадобится O(1) lookup — это отдельный VM-perf
  проект (настоящая хеш-таблица), не относящийся к Стадии 23 и не
  требующий языкового интерфейса вообще.
- **Итерируемое (Iterable)** ✅ — реализована. Iterator protocol
  (grilled): один prelude-интерфейс `Итерируемое[T] { функ следующий()
  -> Опция(T) }` — НЕ пара "производитель итератора"+"итератор"
  (Rust IntoIterator/Iterator), сам реализующий тип — свой же итератор,
  мутирует внутреннее состояние между вызовами через `это.поле = ...`
  (это: Т — immutable биндинг, Стадия 27, но поле мутируемо — reference
  semantics). Не индексируемый протокол — годится для ленивых/
  бесконечных последовательностей.

  Архитектура: `для x в` БОЛЬШЕ НЕ десахаривается на этапе парсинга (как
  было в Стадии 17) — новый AST-узел `For_In_Stmt` (parser.odin) несёт
  паттерн/`в`-выражение/тело КАК ЕСТЬ, резолвится/типизируется обычным
  образом (резолвер создаёт scope+символы на имена паттерна, typechecker
  — новый `infer_for_in_stmt` инфереит тип `в`-выражения и решает форму:
  `.Array` → fast-path, `.Struct` implements Итерируемое (nominal) →
  iterator-protocol, `.Map` → тот же error-hint про `.записи()`, что
  раньше давала `infer_index_expr`, иначе — diagnostic). Решение пишется
  в `ctx.for_in_infos[stmt]` (тот же принцип, что `Call_Info` — не
  переписывает AST, аннотирует существующий узел) — читает compiler.odin
  (`compile_for_in_stmt`), эмитит байткод НАПРЯМУЮ (без синтетических
  Let_Stmt/While_Expr/Match_Expr, которые раньше строил parser): fast-
  path — тот же байткод-паттерн, что раньше строился десахариванием
  (idx-счётчик, `.Invoke_Collection` "длина", `.Get_Index`); iterator-
  protocol — повторный вызов `.следующий()` + `.Match_Tag`/
  `.Get_Variant_Field` на результат (Есть/Нет, тег 1/0) — те же опкоды,
  что уже использует компиляция `выбор`, без создания синтетического
  `Match_Expr`-узла. Оба пути используют `Loop_Context` (`ctx.loops`)
  тем же способом, что `While_Expr` — `прервать`/`продолжить` работают
  идентично в обеих формах.

  Найденный в процессе баг (не архитектурный, полярность условия):
  fast-path exit-check изначально использовал `Equal` вместо `Equal
  +Negate` (NotEqual — компилируется композицией, отдельного VM-опкода
  нет) — давало ОБРАТНУЮ логику выхода (цикл на пустом массиве пытался
  читать элемент, на непустом — не заходил в тело вообще). Пойман
  полным прогоном e2e-тестов (`test_for_in_empty_array_zero_iterations`/
  `test_for_in_sums_array`), не investigation'ом — эмпирическая
  верификация после КАЖДОГО шага реализации себя оправдала снова.

  4 новых e2e-теста (iterator protocol крутит цикл и суммирует;
  прервать/продолжить внутри iterator-protocol работают; негатив —
  struct без Итерируемое даёт diagnostic) + ВСЕ 9 существующих for-in
  тестов (fast-path на массиве, tuple-деструктуризация `для (к,з) в
  карта.записи()`, вложенные циклы, no-collision между несколькими
  циклами, early-return, пустой массив, map-hint-negative) прошли БЕЗ
  изменений в самих тестах (кроме одного — восстановлен error-hint для
  `.Map`, который раньше жил в `infer_index_expr`, теперь явно
  воспроизведён в `infer_for_in_stmt`). `odin test ./core` — 109/109.
  native/lsp/wasm сборки чисты, дополнительно проверено вживую через
  собранный бинарник (массив + custom-Итерируемое struct + массив
  структур — все три сценария в одном скрипте).

  **Доработка (тот же день)**: пользовательский вопрос "что если
  `следующий()` возвращает тупл из 3 значений?" вскрыл искусственное
  ограничение — изначальная реализация безусловно ЗАПРЕЩАЛА `для (a, b)
  в ...` для Iterator_Protocol (`len(s.names) != 1` → diagnostic), хотя
  T как тупл уже типизировался бы корректно (`unify_types` не
  ограничивает kind T). Убрано: `infer_for_in_stmt`'s Iterator_Protocol-
  ветка теперь деструктурирует T-тупл ТЕМ ЖЕ способом, что fast-path уже
  делает для `Массив((К,З))` (`elem_type.kind == .Tuple &&
  len(elem_type.elements) == len(s.names)`); `compile_for_in_stmt`
  зеркалит fast-path'ов `.Get_Property`-паттерн после извлечения
  значения из `Есть(...)` (`.Get_Variant_Field 0`). 1 новый e2e-тест
  (`для (a, b, c) в ...` над `Опция((Число, Число, Число))`).
  `odin test ./core` — 110/110.

  **Подтверждение (следующий вопрос)**: "а если структура/ADT?" — T
  может быть ЛЮБЫМ типом (struct/enum, не только примитив/тупл),
  `unify_types` не ограничивает kind T, только связывает его с тем, что
  фактически вернул impl — код НЕ менялся, только добавлено покрытие: 2
  новых e2e-теста (`следующий() -> Опция(Точка)` — struct-элемент,
  доступ через `p.поле` в теле; `следующий() -> Опция(Событие)` —
  ADT-элемент, `выбор e` в теле работает без единого спецкейса).
  `odin test ./core` — 112/112. native/lsp/wasm чисто.

**Порядок, если делать** (подтверждено grilling-сессией, см. TASKS.md):
Печатаемое/Арифметика берутся СТРОГО ПОСЛЕДОВАТЕЛЬНО после Стадии 22
закрытия — НЕ объединяются с ней в один заход (22 уже de-risked двумя
Explore-агентами, лёгкий тир 23 — ещё нет; смешивание теряет чистый
checkpoint). Каждый получает СВОЙ короткий Explore/Read-проход перед
Порядком работ (не полный двух-агентный, как у 22, но обязательный —
22 показала, что даже "понятный" механизм прятал реальный блокер,
найденный только investigation'ом, не обсуждением).
Клонируемое — сначала обсуждение семантики. Хешируемое/Итерируемое —
заводить СВОИ стадии с полноценным Explore-investigation, не довесок
к 22/23.

---

### Стадия 24 (grilled — дважды пересмотрено, actor model) — lightweight processes (Elixir/Akka-style)

**Статус**: РЕАЛИЗОВАНА ПОЛНОСТЬЮ. Первый grilling-раунд спроектировал
CSP-style shared-memory `Канал(T)` + generic `дай`-yield корутины
(Go/Lua-style) — при обсуждении реальной мотивации ("хочу лёгковесные
Elixir/Akka-like корутины") выяснилось несовпадение: shared-memory
каналы ≠ actor model (Elixir/Akka изолируют состояние per-process,
общаются ТОЛЬКО message-passing). Второй раунд спроектировал ПОЛНОСТЬЮ
actor-model дизайн (CSP-каналы и generic-генераторы убраны из scope
целиком). Explore + Порядок работ + реализация (Task 43-49, см.
TASKS.md) — все 7 пунктов Порядка работ и 3 находки по ходу (see ниже)
закрыты, 8 e2e-тестов в `e2e_test.odin`, `odin test ./core` 123/123,
native/lsp/wasm чисто.

**Что**: single-thread cooperative actor model. `запусти <вызов>`
порождает процесс и возвращает типизированный хэндл `Процесс(T)` (T —
тип принимаемых сообщений). `отправить(процесс, сообщение)` кладёт
сообщение в FIFO-mailbox процесса (обычный вызов функции, silent no-op
если процесс мёртв — Erlang-поведение, не `Результат`). `получить()` —
builtin внутри тела процесса, блокирует (кооперативно yield'ит) до
следующего сообщения. Тело процесса — Erlang-style: рекурсивная
функция, явное state через параметры, `выбор получить()` на
ADT-сообщение (не Akka-style мутабельный struct+метод — противоречило
бы функциональному уклону языка).

**Пример синтаксиса** (из грилинга):
```
тип Сообщение = перечисление
	Увеличить
	Прочитать(Процесс(Число))
конец

функ счётчик(состояние: Число) -> Пусто
	выбор получить()
		Сообщение.Увеличить -> счётчик(состояние + 1)
		Сообщение.Прочитать(отвечающему) ->
			отправить(отвечающему, состояние)
			счётчик(состояние)
	конец
конец

функ старт() -> Пусто
	пер proc: Процесс(Сообщение) = запусти счётчик(0)
	отправить(proc, Сообщение.Увеличить)
конец
```

**Низкоуровневый scheduler-механизм** (не изменился между раундами —
это примитив ПОД actor-моделью, не пользовательская абстракция):
дёшево ИМЕННО для этой VM (см. `lang-design-notes.md` §8) —
`VM.frames`/`VM.stack` (vm.odin:18) уже живут в куче (`[dynamic]`), не
на нативном стеке хоста, значит suspend/resume не требует
asm/setjmp/OS-fiber — только смена указателя, какой процесс сейчас
"current". `execute()` (vm.odin:800, сейчас `for len(vm.frames) > 0
{...}` — монолитный run-to-completion) переводится на работу над
`current.frames`/`.stack`; `получить()` без сообщения в очереди — новый
выход из цикла (`return` из `execute()`, `ip` уже на следующей
инструкции) — resume = повторный вызов `execute()` с тем же процессом,
без отдельной resume-логики.

**Решённые вопросы (grilled, два раунда)**:
1. **Параллелизм**: single-OS-thread cooperative (Lua/JS-style), БЕЗ
   реального параллелизма — переспрошено явно ВО ВТОРОМ раунде (после
   смены на actor-фрейминг) и подтверждено снова. `gc.odin`/весь VM
   спроектированы под ОДНОГО mutator'а — M:N потребовал бы concurrent
   GC, отдельный большой проект без текущего задела. Ценность
   actor-модели (изоляция, fault containment) не требует параллелизма
   как предусловия — BEAM был single-threaded per scheduler годами до
   SMP (добавлен в R11B, 2006), actor/fault-tolerance модель уже тогда
   была главной фичей.
2. **Copy-on-send**: автоматический REFLECTIVE deep-copy по умолчанию
   для ЛЮБОЙ структуры при отправке в mailbox — НЕ требует explicit
   `реализация Копируемое` (иначе безопасность зависела бы от того,
   вспомнил ли автор типа объявить Копируемое). `реализация Копируемое`
   (Стадия 23) — опциональный override для кастомной семантики (напр.
   не копировать кэш-поле). Примитивы (Число/Булево) и неизменяемые
   строки — без копии, безопасно шарятся.
3. **Supervisor tree** (restart-стратегии, link/monitor) — ВНЕ scope
   v1, отдельная будущая стадия ПОВЕРХ готового v1-примитива (нужен
   работающий spawn/mailbox/crash ДО того, как проектировать
   restart-политики над ним).
4. **Mailbox**: строгий FIFO (Akka-style), НЕ selective receive
   (Erlang-style паттерн-матчинг с пропуском несовпадающих сообщений
   из середины очереди) — известный источник багов (O(n)-скан,
   mailbox explosion при вечно не совпадающем ожидании).
5. **Тело процесса**: Erlang-style (рекурсивная функция + `выбор` на
   ADT-сообщение), не Akka-style (мутабельный struct+метод) —
   естественно продолжает уже принятое в языке (Опция/Результат как
   ADT, `выбор` с exhaustiveness как основной механизм ветвления).
6. **Адресация**: новый generic-тип `Процесс(T)` (форма как у
   `Опция(T)`/`Массив(T)`) — НЕ переиспользует `Канал(T)` из первого
   раунда (разная семантика: mailbox на процесс, не два равноправных
   конца). `запусти` теперь возвращает значение (раньше был
   fire-and-forget statement) — эта деталь синтаксиса поменялась между
   раундами. `отправить(процесс, сообщение)` — обычный вызов функции,
   НЕ новый оператор (`<-` рассматривался, отклонён — меньше новой
   грамматики).
7. **Generic `дай`-генераторы** (ленивые итераторы, ортогонально
   message-passing) — ПОЛНОСТЬЮ убраны из scope, не нужны. Стадия 24 —
   только actor model, не generic coroutines.
8. **Отправка мёртвому процессу**: тихий no-op (Erlang-поведение), НЕ
   `Результат` — синхронная проверка живости на момент send всё равно
   гонка (процесс может упасть микросекундой позже), `Результат` создал
   бы ложное чувство надёжности. Настоящий способ узнать о падении —
   monitor/link (часть supervisor'а, уже отложен в п.3).

**Не исследовано (нужен Explore перед Порядком работ — investigation-
детали, не пользовательские решения)**:
- Компиляция `запусти`/`получить`/`отправить` — новые Opcode или
  builtin-функции? compiler.odin/vm.odin.
- Типизация `Процесс(T)` как generic-типа, интеграция с
  инфраструктурой дженериков (Стадия 7 ✅).
- Reflective deep-copy механизм (для copy-on-send по умолчанию) — НОВЫЙ,
  отдельный от Копируемое, нужен обход `Type`/`Aggregate_Value` полей;
  возможно переиспользуем GC's value walker (уже обходит те же
  структуры для root-marking, gc.odin) как отправную точку.
- GC root-walking по множеству стеков процессов (сейчас — один
  `vm.stack`/`vm.frames`, тривиальный корень) — gc.odin.
- Mailbox — структура данных: простая FIFO-очередь на процесс (проще,
  чем предполагалось в первом раунде — не нужен wait-list с fairness
  между МНОГИМИ ожидающими одного канала, конкретный процесс блокируется
  на СВОЁМ mailbox).
- Синтаксис `Процесс(T)` + `запусти`-как-выражение (не statement, раз
  теперь возвращает значение — отличается от plain-statement дизайна
  первого раунда) — parser.odin.

**Prerequisite**: Стадия 7 ✅ (generic `Процесс(T)`). Стадия 23
(Копируемое) — НЕ блокер (reflective default copy-on-send работает без
неё), нужна только для опционального кастомного override.

**Explore-находки** (см. также §Стадия 25 выше — совпадающие ловушки):
`Процесс(T)` типизируется НЕ через Struct/Enum-механизм схем
(`Type_Scheme`/`instantiate_scheme`), а как ТРЕТЬЯ ветка в `Type_Generic`-
цепочке `resolve_type_node` (type_cheker.odin ~1871-1886), рядом с
`Массив`/`Соответствие` — `new_process_type(t) -> ^Type` строит
`^Type{kind=.Process, element_type=t, ...}` напрямую, без InferVar/схем.
`CallFrame` не имеет обратной ссылки на VM — `frames`/`stack` независимо
свопаемы между процессами без протаскивания "текущего процесса" через
каждый opcode-обработчик `execute()`.

**Порядок работ (grilled)**:
1. **execute()/suspend-resume**: новый опкод `.Receive`. `execute()`
   возвращает `Exec_Result :: enum { Completed, Suspended }`. При
   пустом mailbox — `return .Suspended` ДО `frame.ip += 1` (ip остаётся
   на самом `.Receive`) — resume = повторный вызов `execute()`,
   естественно перепроверяет mailbox без отдельного resume-состояния.
2. **VM.processes**: `[dynamic]^Process_Value` — планировщик round-robin
   по нему (простой вариант, без runnable/waiting очередей — тот же
   принцип простоты, что уже подтверждён для Соответствие/линейный
   скан, Стадия 23-Хешируемое).
3. **Синтаксис — три разных механизма, не один**:
   - `запусти <вызов>` — новый `nud()`-префикс (parser.odin) + новый
     опкод `.Spawn` (захватывает callee+аргументы БЕЗ выполнения,
     создаёт новый `Process_Value`, кладёт `Процесс(T)`-хэндл на стек
     ТЕКУЩЕГО процесса).
   - `получить()` — bare-имя builtin'а (тот же механизм, что `длина`/
     `паника`/`Ошибка`, `BUILTIN_CTORS`), компилируется в `.Receive`.
   - `отправить(процесс, сообщение)` — обычная 2-арг builtin-функция,
     БЕЗ нового опкода.
4. **Reflective copy — compile-time dispatch, паттерн Печатаемого**
   (Стадия 23, `Print_Value` Call_Kind): тип сообщения известен
   статически на месте `отправить`. Реализует `Копируемое` — компилятор
   вставляет `.клонировать()` ПЕРЕД builtin'ом; не реализует — runtime-
   обработчик сам обходит структуру (адаптация `value_to_display_
   string`'s walker'а, vm.odin — cycle-protection уже есть, тот же
   паттерн, только вместо строки строит через `gc_new` копию).
5. **Process lifecycle**: `Process_Value.is_alive: bool`. `execute()`
   вернул `.Completed` → планировщик ставит `is_alive=false`, swap-
   remove из `vm.processes`, явно чистит `frames`/`stack`
   (`clear(&process.frames)`/`.stack`, тот же паттерн, что pool-release
   `Array_Value.elements`/`Map_Value.entries`, gc.odin) — не дожидаясь
   GC. `отправить` на мёртвый процесс — тихий no-op (уже решено ранее),
   проверка через `is_alive`.
6. **старт() = процесс #0** — та же `Process_Value`-инфраструктура, без
   спецкейсов. Программа завершается СРАЗУ по возврату процесса #0
   (Go-`main()`-style), НЕ ждёт осиротевшие процессы (supervisor tree
   вне scope v1). `получить()` на собственном mailbox `старт()` даёт
   ожидание ответа без отдельного join/monitor-примитива. T для
   `старт()` выводится из паттернов `выбор получить()` в его теле — тем
   же механизмом, что и generic-вывод остальных типов.
7. **GC**: `mark_roots` (gc.odin) — цикл по `vm.processes`, не только
   `vm.stack`. Новые `mark_value`-кейсы для `Process_Value`/`Mailbox`.

**Effort**: не оценено численно — самый крупный feature этой сессии по
количеству затронутых подсистем (VM execution loop, GC, 2 новых
опкода, новый Type_Kind, parser), но каждый пункт имеет ясный прецедент
в уже существующем коде (не архитектурная неопределённость, объём
работы).

**Реализация (Task 43-48 готовы, см. TASKS.md)**: Value/Type foundation,
VM scheduler, опкоды `.Spawn`/`.Receive`, парсер (`запусти`-префикс,
`Spawn_Expr` оборачивает `Call_Expr`, резолвер/typecheck/compiler
переиспользуют существующие Call_Expr-пути), typecheck (`получить`/
`отправить`/`себя` — BUILTIN_CTORS, `Процесс(T)` через `Type_Generic`),
copy-on-send (reflective + explicit Копируемое), GC multi-process root
walking — всё реализовано и сквозно протестировано (spawn → send →
suspend/resume → self-handle reply, негативные типовые ошибки,
dead-process no-op, deadlock detection).

**Найдено по ходу (не было в Порядке работ выше)**:
- `install_standard_symbols` (resolver.odin) резервирует builtin-имена в
  ОБЩЕЙ global scope, разделяемой со всеми пользовательскими top-level
  декларациями (`module.scope = ctx.global_scope`) — `получить`/
  `отправить` слишком частые глагольные имена (уже были top-level
  функциями в 2 существующих e2e-тестах: `test_http_url_parsing`,
  `test_math_and_logic`), конфликтовали с "уже объявлен". Фикс:
  `register_named_symbol` теперь разрешает пользовательской декларации
  ПЕРЕТЕРЕТЬ существующий символ, если тот `.Builtin` (не настоящая
  декларация) — обычное затенение, а не столкновение. Настоящий
  конфликт двух user-деклараций остаётся ошибкой.
- `получить()` возвращает InferVar (тип сообщения неизвестен на месте
  вызова) — но `infer_match_expr` (`выбор получить() { ... }`) ТРЕБОВАЛ
  `subject_type.kind == .Enum` СТРОГО, без попытки унификации с
  паттернами (в отличие от заявленного в Порядке работ выше "тем же
  механизмом, что и generic-вывод остальных типов" — на деле такого
  механизма для InferVar-subject'а не существовало). Добавлена unify-
  ветка: если subject — непривязанный InferVar, ищем ПЕРВЫЙ arm с
  квалифицированным паттерном (`Тип.Вариант`, `Pattern_Constructor.
  module_name`), резолвим `Тип` как enum, `bind_infer_var` — тот же
  примитив, что везде в файле. Практическое следствие: `выбор
  получить()` ТРЕБУЕТ полностью квалифицированных паттернов
  (`Сообщение.Увеличить`, не голое `Увеличить`) — как раз то, что
  ROADMAP-пример и так уже показывал.
- T процесса для `запусти f(...)` (когда f объявлена ПОСЛЕ места
  `запусти` по файлу) требует typecheck тела f ДО обычного ПРОХОД 4
  порядка — `ensure_body_checked` (мемоизация по `Symbol_Id`,
  `symbol_to_func_decl` строится в ПРОХОД 2) даёт корректный результат
  при любом порядке деклараций, т.к. T зависит только от получить()-
  паттернов ВНУТРИ f, не от вызывающих.
- Пункт 6 Порядка работ утверждал "получить() на собственном mailbox
  старт() даёт ожидание ответа без отдельного join/monitor-примитива" —
  на деле для ЭТОГО нужен способ передать спавненному процессу СВОЙ
  адрес, а такого примитива в Порядке работ не было (grilling не дошёл
  до этой детали). Добавлен `себя()` — bare builtin (тот же механизм,
  что `получить`), возвращает `Процесс(T)`-хэндл ТЕКУЩЕГО процесса (T —
  тот же message-var, что у `получить()` в этой же функции). НЕ join/
  monitor (следит за ЛАЙФСАЙКЛОМ процесса) — просто адрес для ответа
  через обычный `отправить`, ровно то, что "получить() ожидание ответа"
  и имелось в виду. Полный цикл (`запусти` → `отправить(..., себя())` →
  suspend на `получить()` → удалённый `отправить` → resume → результат)
  протестирован end-to-end.

**Task 43-49 — все реализованы, протестированы, ЗАКРЫТЫ.** 8 новых
e2e-тестов в `e2e_test.odin` (spawn+send без ожидания; self-handle
reply round-trip; copy-on-send изоляция, различает by-reference от
reflective-copy по значению; explicit Копируемое-override; отправить
мёртвому процессу — silent no-op; genuine deadlock detection; 2
негативных типа — запусти не-функции, отправить не-Процесс).
`odin test ./core` — 123/123 (0 регрессий). native/lsp/wasm — чисто.

---

### Стадия 25 ✅ — интерфейсы для перечислений

**Статус**: реализована. Блокер оказался НЕ чисто отсутствием
investment — реальная цепочка из 3 уровней, каждый со своим фиксом:

1. **typecheck guard** — безусловный `if target_type.kind == .Enum &&
   d.interface_name != "" { report(...); continue }`
   (type_cheker.odin ~1622) снят. `enum_type.implemented_interfaces`
   (не инициализировался в ПРОХОД 1, в отличие от Struct) — добавлено.
2. **typecheck coercion** — `unify_types`/`types_are_equal`'s интерфейс-
   коэрсия хардкодила `left.kind == .Struct` (2 копии) — расширено на
   `.Enum`. То же для `check_expr`'s `ctx.interface_casts`-populating
   ветки.
3. **рантайм** — `Interface_Value.data` был жёстко `^Aggregate_Value`
   (compiler.odin) — расширен до `Value` (union уже включает
   `^Variant_Value`). `.Cast_Interface` (vm.odin) паниковал на всём,
   кроме структуры — теперь принимает Aggregate_Value ИЛИ Variant_Value
   (vtable-механизм по имени `"Тип::метод"` уже был kind-агностичен).
   `.Set_Property` через интерфейс (мутация поля) остаётся
   struct-only — Variant_Value не имеет settable-полей, даёт понятную
   runtime-ошибку вместо краша. GC mark/sweep (`gc.odin`) поправлен под
   новый тип поля (`Value`, не голый указатель).

**Найденные попутно 2 бага** (оба недостижимы ДО этой стадии — enum'ы не
реализовывали интерфейсы вообще):
- `compiler.odin`'s `case ^Property_Expr:` — ранний `return` для
  БЕЗАРГУМЕНТНОГО конструктора варианта (`Фигура.Линия`, без скобок) не
  вызывал `maybe_emit_interface_cast` (документированный как
  обязательный для ранних `return`, но пропущенный именно тут). Payload-
  варианты (`Событие.Данные(42)`, идут через `Call_Expr`) уже вызывали
  его корректно.
- `instantiate_type`'s `case .Enum:` (type_cheker.odin) не копировал
  `implemented_interfaces` при инстанциации generic enum'а (у `.Struct`
  это уже было исправлено В Стадии 7 с явным комментарием про этот же
  класс бага) — молча терялась реализация интерфейса при КАЖДОЙ
  инстанциации `Опция(Число)`/`Опция(Строка)` и т.д.

**Расширение operator sugar (Ord/Eq/Арифметика/Печатаемое) на `.Enum`**:
все 5 site'ов, где Стадия 22/23 проверяли `left_t.kind == .Struct` для
активации sugar, расширены на `|| left_t.kind == .Enum` — без этого
`реализация Сравниваемое для Опция` регистрировалась бы, но `<`/`==`
на `Опция`-значениях НЕ активировали бы sugar вообще.

**Отдельный найденный баг (не enum-специфичный)**: sugar-проверка "тот
же ли тип у операндов" (`Сравниваемое`/`Равнозначное`/Арифметика)
использовала `left_t == right_t`/`!=` (голое сравнение указателей) —
для generic enum'а с НУЛЕВЫМ-payload вариантом (`Опция.Нет()` — T не
выводится из самого значения) это ложно отвергало сравнение с ещё-не-
связанным T. Исправлено на `unify_types(left_t, right_t)` (связывает
InferVar, как и остальные InferVar-направленные места в файле) во ВСЕХ
трёх местах (`infer_arithmetic_sugar`, Comparable-ветка, Equatable-
ветка). Подтверждает исходный мотивирующий пример ROADMAP дословно:
`(Опция.Есть(5) < Опция.Есть(10)) и (Опция.Нет() < Опция.Есть(1))` →
`true`.

**Верификация**: 5 e2e-тестов (payload-less вариант как интерфейс-арг;
payload-вариант как интерфейс-арг; Копируемое на enum; Опция реализует
Сравниваемое включая нулевой-payload вариант; заменён обсолетный
негативный тест на позитивный). `odin test ./core` — 115/115 (0
регрессий). native/lsp/wasm сборки чисты.

**Effort**: не оценено.

---

### Стадия 26 (grilled, три раунда) — `panos mod`: встроенный пакетный менеджер

**Статус**: архитектура и все ключевые решения прошли grilling явно —
включая крупный побочный разговор о выборе Odin как языка реализации
(TLS-пробел в `core:net` вскрылся по ходу, разобран и закрыт отдельно,
не привёл к смене языка — см. ниже). Touch-точки (конкретные Odin-файлы/
функции) НЕ Explore-исследованы — Порядок работ ниже пока набросок.

**Что**: подкоманды у самого бинарника `panos` (`panos mod init`/
`panos get`/аналоги) в духе `go mod` — ОДИН бинарник, не отдельный
инструмент, нативная Odin-реализация (не panos-VM-скрипт). Решено явно:
существующий заготовочный проект `pan`
(`/Users/gaidar/dev/panosiki/pan/` — README + demo flag-parser, 0
коммитов) архитектурно не подходит под это решение (отдельный бинарник,
cargo-стиль) — становится неактуальным, не трогается (не удаляется/не
архивируется), план живёт здесь, не там.

**Зачем**: сейчас единственный способ получить чужой код — руками
скопировать `.ps`-файлы в `модули/` или выставить `PANOS_STDLIB`. Ноль
версионирования, ноль воспроизводимости сборки, ноль автоматизации.

**Побочный разговор: не стоит ли уйти с Odin (Zig/Nim)?** Всплыло при
обсуждении TLS-пробела (`core:net` не даёт TLS, документировано и в
`std/сеть/http.ps`'s собственном комментарии). Разобрано и закрыто:
"нет TLS в core std" — норма для системных языков (Rust std тоже без
TLS, нужен `rustls`/`native-tls`; Zig аналогично Odin, C-интероп на
BearSSL/OpenSSL; Go — скорее исключение, сделал полный TLS-стек в std
сам). Реальный фикс нашёлся в экосистеме Odin, не требует смены языка
(см. "Уже существующая инфраструктура" ниже). Масштаб проблемы —
только сетевой стек (эта стадия + `std/сеть/http.ps`), не касается
компилятора/VM/GC/LSP/WASM (26 стадий работы, в основном уже сделано).
Миграция ради экономии ~сотни строк FFI/интеграции — несоразмерный
размен, отклонено.

**Odin сам сознательно без package-менеджера** — официальная позиция:
"Odin никогда официально не будет поддерживать package manager",
рекомендуемый подход — ручное копирование/vendoring стороннего кода к
себе в репозиторий, версия фиксируется физическим наличием исходников
в дереве. `vendor:`-префикс импорта — НЕ общая директория для
зависимостей, а закрытая коллекция, курируемая самой Odin-командой
(raylib/SDL2/OpenGL и т.п.), не для сторонних библиотек вроде
`laytan/odin-http`. Значит сам panos-репозиторий (host-Odin-код, не
panos-язык) вендорит `laytan/odin-http`/`Up05/toml_parser` вручную —
тем же способом, что уже сделано для `back` (backtrace, того же
laytan) — в `external/`, как plain tracked files, без `.git` внутри.
Забавная симметрия: строим автоматизацию для panos-языка поверх
экосистемы, которая от такой автоматизации сама сознательно
отказалась.

**Уже существующая инфраструктура (переиспользуется, не изобретается
заново)**:
- `модули/`-fallback уже в резолвере (`resolver_import_native.odin:12`,
  `resolve_import_path(import_spec, "модули")`) — vendoring зависимостей
  туда работает БЕЗ единой правки в резолвере.
- [`laytan/odin-http`](https://github.com/laytan/odin-http) — HTTP/HTTPS
  клиент для Odin, обычный `import` (не ручной `foreign`), TLS через
  OpenSSL (vendored на Windows, системный на Linux/macOS). Тот же автор,
  чьи `back` (backtrace) и `setup-odin` CI Action panos уже использует —
  проверенный источник. Решает fetch-транспорт целиком.
- [`Up05/toml_parser`](https://github.com/Up05/toml_parser) — TOML-парсер
  для Odin (v1.2.0, в официальном package registry) — манифест парсится
  им, не написанным с нуля кодом. `std/кодирование/toml.ps` (panos-
  уровневый парсер) здесь НЕ применим — манифест парсит нативный
  Odin-хост, не panos-VM. **Однонаправленный**: только parse/unmarshal
  (текст → `^Table`/Odin-структура), НЕТ marshal/encode/write в обратную
  сторону — проверено (`grep` по исходникам, ни одной `marshal`/`encode`/
  `write`-функции). Для `панос.lock` (и, возможно, `панос.toml` при
  `panos mod init`) нужен СВОЙ маленький TOML-writer — библиotека не
  поможет. Задача мала: panos'у не нужен произвольный TOML (вложенные/
  inline-таблицы, мультистрочные строки), только свой узкий манифест/
  lock-формат (плоские секции, `ключ = значение`, простые массивы) —
  по сути шаблонный `fmt.fprintf`, не "парсер наоборот".
- `core:compress/gzip` (Odin core) — распаковка `.tar.gz` наполовину
  готова, нужен только сам TAR-контейнер-парсер (см. ниже).

**Fetch-механизм (grilled, полностью решён)**: HTTP-скачивание архива
по git-host'овским archive-ссылкам (`.../archive/refs/tags/vX.Y.Z.tar.gz`
— GitHub и большинство хостов отдают это бесплатно, без своего
registry/proxy-сервера) — НЕ git-subprocess, НЕ сырой git-протокол.
Только `.tar.gz`, НЕ `.zip` — TAR-контейнер простой (512-байтные блоки,
фиксированные оффсеты, никакого сжатия внутри самого формата — ~1-2 дня
на read-only парсер обычных файлов/директорий), ZIP заметно сложнее
(Central Directory в конце файла, обратный скан на EOCD-сигнатуру,
Zip64) — не нужен, раз выбор формата свободный.

**Решённые вопросы (grilled)**:
1. Разрешение версий — ПЛОСКИЙ список прямых зависимостей, БЕЗ
   транзитивного резолва (не Minimal Version Selection). Каждый проект
   явно объявляет ВСЕ свои зависимости, включая нужные его же
   зависимостям. Zero diamond-конфликтов по построению — можно
   добавить MVS отдельной стадией позже, если экосистема разрастётся.
2. Схема версионирования — обычные semver git-теги (`v1.2.3`), БЕЗ
   Go-style "major-версия в пути импорта" — прямое продолжение решения
   #1 (весь смысл той Go-конвенции — предсказуемо разруливать diamond-
   граф, а мы явно отказались от транзитивного резолва).
3. Имена файлов манифеста/lock — КИРИЛЛИЦА: `панос.toml`/`панос.lock`
   (консистентно с языком, несмотря на то что `go mod`/`Cargo.toml`
   послужили референсом по духу, не по букве).
4. Целостность — SHA-256 hash-lock в `панос.lock` (go.sum-style),
   проверяется при каждой установке. Защита от мутируемости git-тегов
   (тег можно молча пересоздать на другой коммит) — базовая гигиена,
   не добавлять задним числом как breaking change формата.

**Prerequisite**: нет формального.

**Effort**: не оценено — требует Explore-прохода (конкретные Odin-файлы
для новых subcommand'ов, интеграция `laytan/odin-http`/`Up05/toml_parser`
как зависимостей самого panos-репозитория) прежде, чем давать оценку.

---

### Стадия 27 (grilled, один раунд) — `конст`: неизменяемые биндинги

**Статус**: реализована. Все 10 шагов Порядка работ выполнены как
запланировано (LSP hover, шаг 9, сознательно пропущен — опциональный,
не блокирует). 4 новых e2e-теста (позитив, negative-diagnostic, 2
regression на Explore-находки). `odin test ./core` — 100/100.
native/lsp/wasm сборки чисты.

**Расширение (тот же раунд)**: пользователь спросил про конст-ПАРАМЕТРЫ
функций отдельно — разведено на 2 независимые оси: (1) запрет
переприсвоения биндинга (что и реализовано) vs (2) copy-on-call
семантика (изоляция от мутации через параметр — это НЕ конст, это
пересекается с уже запланированной Копируемое, следующим кандидатом
Стадии 23, и осталось НЕ в скоупе). Для оси (1) выбран Kotlin/Swift-
style: ВСЕ параметры функций и лямбд immutable ПО УМОЛЧАНИЮ (не opt-in
`конст` перед параметром, как в C++/Rust) — `Symbol.is_const = true`
проставляется прямо в `resolve_function_body` (resolver.odin:515) и
`Lambda_Expr`-ветке `resolve_expr` (resolver.odin:867), без нового
синтаксиса. Никакого opt-out на v1 (чистое соответствие выбранной
модели — если параметр нужно мутировать, копируется в локальный `пер`
внутри тела). BREAKING CHANGE — проверено эмпирически (полный прогон
тестов): сломался ТОЛЬКО собственный regression-тест исходной Стадии 27
(`test_function_params_still_reassignable`, проверял старое поведение,
переписан в `test_function_params_are_immutable_by_default` +
`test_function_params_still_readable`), весь `std/*.ps` не переприсваи-
вает параметры нигде — blast radius пуст. `odin test ./core` — 101/101.

**Что**: новое ключевое слово `конст` — биндинг-форма, параллельная
`пер`, запрещающая ПЕРЕПРИСВОЕНИЕ имени после объявления (`конст x = 5;
x = 10` → ошибка компиляции). НЕ deep immutability — если `x` ссылается
на структуру, `x.поле = 5` по-прежнему работает (у panos структур
reference semantics, `конст` фиксирует только САМ биндинг, не то, на что
он указывает через дальнейшие Set_Property/Set_Index). Второй уровень
(deep immutability, Rust-style const-correctness через весь type
system) осознанно НЕ в scope — отдельная, кратно более крупная фича,
если вообще понадобится.

**Развилка (grilled)**:
- [x] Уровень: **binding-immutability** (JS `const`/Kotlin `val`-style),
  не deep immutability. Дёшево (resolver-флаг + один diagnostic-check),
  не трогает существующую семантику `пер`/Set_Property/Set_Index, не
  требует протаскивать mutability через type checker.

**Explore-находки (эмпирически, тестовыми прогонами)**:
- Переприсваивание параметров функции УЖЕ работает сегодня (`функ
  f(x: Число) x = x + 1 x конец` → `6`, без ошибок) — `конст` НЕ
  распространяется на параметры автоматически (не входит в scope
  фичи), их текущее поведение не меняется этой стадией.
- Shadowing в ТОМ ЖЕ scope УЖЕ запрещено резолвером (`пер x = 5; пер
  x = 10` в одном scope → `"Имя x уже объявлено"`) — независимо от
  const/mut, `конст` ничего не ломает и не требует отдельного кейса,
  наследует существующее правило автоматически.
- Shadowing во ВЛОЖЕННОМ scope УЖЕ работает (каждый scope — независимый
  `Symbol`, проверено: внешний `x=5`, внутри `если` блока свой `пер
  x=10` — снаружи по-прежнему видно `5`) — `is_const`, будучи полем
  САМОГО `Symbol`, автоматически корректен здесь без спецкейсов.
- LSP hover (`handle_hover`, lsp/lsp_server.odin:292) СЕЙЧАС показывает
  ТОЛЬКО `prune_type(typ).name` (напр. "Число"), никакого `пер`/`конст`-
  префикса нет вообще (hover не делает symbol-lookup, только
  node_types) — конст-осведомлённость в hover была бы NET-NEW
  доработкой, не правкой существующего — вынесена как optional/
  deferred (см. Порядок работ, шаг 6).

**Порядок работ (file:line, после Explore)**:
1. `core/lexer.odin:157` — рядом с `case "пер": return .Let` добавить
   `case "конст": return .Const` (новый `Token_Kind.Const`).
2. `core/parser.odin:212` — `Let_Stmt` получает поле `is_const: bool`.
3. `core/parser.odin:1146-1150` (`parse_stmt`) — `case .Let: return
   parse_let_stmt(p)` → `case .Let, .Const: return parse_let_stmt(p)`.
4. `core/parser.odin:1412-1431` (`parse_let_stmt`) — перед `next_token`
   (которая сейчас безусловно съедает `.Let`) прочитать `is_const :=
   peek_token(p.stream).kind == .Const`, присвоить `stmt.is_const`.
5. `core/resolver.odin:285-298` (`new_symbol`) — новый именованный
   параметр `is_const: bool = false` (форма `is_pattern_binder`),
   `core/resolver.odin:16-28` (`Symbol`) — поле `is_const: bool`.
6. `core/resolver.odin:710-720` (`resolve_stmt`, `case ^Let_Stmt`) —
   `new_symbol(..., is_const = s.is_const)`.
7. `core/type_cheker.odin:2749` (`infer_binary_expr`, `case .Assign`) —
   ПЕРЕД существующей unify_types-проверкой: если `e.left` — это
   `^Ident_Expr`, резолвить `Symbol` через `ctx.res.node_symbols[e.left]`
   и `symbol_at`, если `.is_const` — `report(...)` ("Type Error:
   попытка переприсвоить константу '%s'" или аналог). Property_Expr/
   Index_Expr (присвоение через `.`/`[]`) — НЕ входят в эту проверку
   (не биндинг, а поле/элемент).
8. Codegen (compiler.odin) — БЕЗ ИЗМЕНЕНИЙ (typecheck-diagnostic
   останавливает пайплайн до компиляции, тот же гейт, что у всех
   остальных diagnostic'ов).
9. (Опционально, вне core-скоупа фичи) LSP hover — показывать `конст`-
   префикс, если `Symbol.is_const` — требует добавить symbol-lookup в
   `handle_hover` (сейчас его там нет). Можно сделать отдельным
   маленьким шагом ПОСЛЕ core-фичи, не блокирует.
10. e2e-тесты (core/e2e_test.odin): позитив (конст-биндинг компилируется
    и исполняется как обычный `пер`, читается нормально), негатив
    (переприсваивание конст даёт diagnostic), shadowing во вложенном
    scope конст/пер друг друга не блокирует (regression, confirms
    Explore-находку выше), параметры функций по-прежнему переприсваи-
    ваемы (regression, confirms Explore-находку выше).

Compound-присваиваний (`+=` и т.п.) в языке нет (проверено — только
`.Assign`/`=`) — шаг 7 не нужно дублировать под другие операторы.

**Prerequisite**: нет формального.

**Effort**: маленький тир — один новый keyword, один AST-флаг, один
resolver-флаг, один typecheck-check, БЕЗ codegen-изменений и БЕЗ
interface-инфраструктуры (дешевле любого кандидата Стадии 22/23).

---

### Стадия 28 ✅ — generic-интерфейсы

**Статус**: реализована. Оказалась ЗНАЧИТЕЛЬНО проще первоначальной
оценки ("объём может быть больше 3 найденных точек", "нужен try_generalize/
scheme, как у Struct/Enum") — при проработке выяснилось, что try_generalize
для интерфейсов НЕ нужен вообще, реализация свелась к прямой подстановке
в единственной точке (проверка контракта impl'а).

**Что реализовано**: `тип Итератор[T] = интерфейс функ следующий() ->
Опция(T) конец` — интерфейсы с type-параметрами. **Сознательно НЕ
реализовано** (не нужно для Итерируемого, единственного текущего
потребителя): explicit-инстанциация синтаксисом `Итератор(Число)` — ни
в `реализация`-блоках (`decl.interface_name`/`decl.target_type` в
`Impl_Decl` остаются голыми identifier'ами, без типовых аргументов), ни
как аннотация типа параметра (`f(x: Итератор(Число))`). T выводится
ИМПЛИЦИТНО за каждый `реализация`-блок — из конкретных типов, которые
impl подставляет вместо T (`это.значение` типа `Число` даёт `Опция(T)`
→ `Опция(Число)`, T=Число для ЭТОГО impl'а), тем же способом, каким уже
выводится Self с 22 Стадии — никакого явного "T=Число" нигде не пишется.

**Ключевая находка, отменившая исходную оценку**: `instantiate_type`
(type_cheker.odin:720+) не имеет `case .Interface` в своём `#partial
switch` — типы кода `.Interface` проходят её НЕТРОНУТЫМИ (тот же
указатель на выходе, что и на входе, через fallback `return pruned` в
конце). Это ЗНАЧИТ, что Self-идентичность (`params[0] == iface_type` в
`interface_method_types_match`) автоматически переживает подстановку T
— не нужно НИКАКОЙ специальной защиты self-ссылки при инстанциации,
достаточно вызвать `instantiate_type` на всей сигнатуре метода, T
подставится, iface_type — нет. Из-за этого try_generalize/
`collect_free_infer_vars`-расширение (у которого тоже нет `.Interface`-
кейса — цикл-guard понадобился бы, если бы try_generalize использовался)
оказались НЕ НУЖНЫ вообще.

**Механизм** (4 точки, все в `core/type_cheker.odin` кроме первой):
1. `core/parser.odin:78-83` (`Interface_Decl.type_params: [dynamic]string`)
   + `core/parser.odin:770+` (`parse_interface_decl` читает `[T]` после
   имени, симметрично `parse_struct_decl`).
2. ПРОХОД 1 (`case ^Interface_Decl`, ~1351) — `iface_type.generic_origin
   = iface_sym`, если `d.type_params` непусто (симметрично Struct/Enum,
   хотя сам механизм инстанциации иной — см. ниже).
3. ПРОХОД 2 (`case ^Interface_Decl`, ~1456) — резолв `interface_methods`
   обёрнут в `make_decl_type_params`/`ctx.current_type_params`-установку
   (симметрично Struct/Enum), БЕЗ `try_generalize` (не нужен — см.
   находку выше). `resolve_type_node` внутри
   `interface_method_type_from_signature` видит T через
   `ctx.current_type_params`, тем же путём, что поле generic-структуры.
4. Проверка контракта impl'а (ПРОХОД 3, ~1690) — ПЕРЕД вызовом
   `interface_method_types_match`, если `ctx.decl_type_param_order
   [iface_sym]` непуст, строится СВЕЖИЙ subst (новая InferVar на T) и
   `expected_method_type = instantiate_type(ctx, expected_method_type,
   &subst)` — свежая на КАЖДУЮ проверку impl'а, иначе T первого impl'а
   "зацементировался" бы для всех последующих (за счёт unify_types,
   см. ниже, InferVar связывается один раз и остаётся связанной).
   `interface_method_types_match` (type_cheker.odin:1257) — `types_are_
   equal` заменена на `unify_types` для НЕ-Self частей сигнатуры:
   для НЕ-generic интерфейсов ведёт себя идентично (нет свободных
   InferVar — те же результаты, что раньше), для generic — СВЯЗЫВАЕТ T
   с тем, что предоставил impl (`types_are_equal` такое бы отвергла —
   InferVar никогда не "равна" конкретному типу).

**Верификация**: 3 e2e-теста — (1) одна реализация, T конкретизирован;
(2) КЛЮЧЕВОЙ regression-тест — ДВА impl'а одного generic-интерфейса С
РАЗНЫМИ T (Число/Строка), подтверждает отсутствие cross-contamination
между проверками разных impl'ов; (3) негатив — impl нарушает форму
контракта (возвращает `Строка` напрямую вместо `Опция(T)`), `unify_types`
ловит расхождение kind (Enum vs String) так же строго, как раньше
`types_are_equal`. `odin test ./core` — 106/106 (все 6 ранее сделанных
НЕ-generic интерфейсов тоже прогнаны — 0 регрессий от смены
`types_are_equal`→`unify_types`). native/lsp/wasm сборки чисты.

**Prerequisite**: Стадия 7 (Generics) — фактически была готова
(структуры/enum'ы/функции), эта стадия закрыла недостающий кусок её
охвата (интерфейсы).

---

### Стадия 29 ✅ — литеральные шаблоны в `выбор`

**Статус**: реализована. `Pattern_Literal` существовал в AST давно, но
парсер НИКОГДА его не создавал (`parse_pattern` принимал только Ident-based
шаблоны, любой другой токен — сразу parse error), а `classify_pattern`
безусловно репортил "литеральные шаблоны пока не поддерживаются" и
понижал до Wildcard. `infer_match_expr` вдобавок требовал
`subject_type.kind == .Enum` строго — `выбор` на Число/Строка/Булево был
недостижим целиком, не только литеральные паттерны внутри него.

**Что реализовано**: `выбор` теперь принимает subject любого из четырёх
типов — `.Enum` (как раньше), `.Number`, `.String`, `.Bool` — с
литеральными шаблонами (`1 -> ...`, `"да" -> ...`, `истина -> ...`).
Компилируется БЕЗ нового опкода — `.Equal` (уже структурно сравнивает
любые Value, см. Стадия 22) + `.Jump_If_False`, тот же паттерн, что и
обычный оператор `==`. Литеральные шаблоны работают и как под-шаблоны
внутри конструктора варианта (`Событие.Клик(1, y) -> ...`) бесплатно —
`classify_pattern` уже рекурсивен по `expected_fields`, отдельный код не
понадобился.

**Exhaustiveness — асимметрия по типу домена**:
- `Булево` (2 значения) — НАСТОЯЩАЯ проверка покрытия, как у enum'ов:
  ветки `истина`/`ложь` обе присутствуют → `_` НЕ обязателен. Отдельный
  2-элементный `bool_covered` массив в `check_match_coverage`, индексация
  по значению литерала (`pi.literal_expr.(^Boolean_Expr).value`).
- `Число`/`Строка` (неперечислимый домен) — `_`/биндер-ветка ОБЯЗАТЕЛЬНА,
  иначе Type Error. Нет способа перечислить "что осталось" для
  бесконечного домена, в отличие от enum/Булево.

**Отклонённая (не реализованная) возможность — отрицательные числовые
литералы** (`-1 -> ...`): парсер их поддержать не может БЕЗ более
глубокой переработки грамматики — `parse_match_expr` парсит subject
через `parse_expr(p, 0)` без явной границы на переводе строки, значит
`выбор x\n-1 -> ...` неотличимо на уровне токенов от продолжения
subject-выражения инфиксным вычитанием (`x - 1`) — ведущий `-` в
Pratt-парсере это ОДНОВРЕМЕННО валидный префиксный (унарный минус) И
инфиксный (вычитание) оператор, и без newline-aware терминации
выражений парсер жадно поглощает вторую строку как продолжение первой.
Обнаружено вручную (не Explore) — реализация была написана, тест дал
непонятную ошибку разбора ("Arrow" вместо ожидаемого паттерна), причина
найдена трассировкой вручную. Убрано из scope, не полумера: попытка
"почти работает, но ловушка на конкретной комбинации subject+первая
ветка" хуже явного отсутствия фичи.

**Файлы**: `core/parser.odin` (`parse_pattern` — три новых `if`-ветки
для Number/String/Boolean); `core/resolver.odin` (`resolve_pattern` —
`Pattern_Literal`-кейс перестал репортить ошибку, резолвит `p.value` как
обычное выражение); `core/type_cheker.odin` (`Match_Arm_Kind.Literal` +
`Pattern_Info.literal_expr`, `classify_pattern` — новый кейс с
type-check литерала против `expected_type`, `infer_match_expr` —
Enum-only gate расширен на Number/String/Bool, `check_match_coverage` —
Bool-exhaustiveness + обязательный catch-all для Number/String);
`core/compiler.odin` (`compile_pattern` — новый `.Literal`-кейс,
`compile_expr` на `literal_expr` + `.Equal` + `.Jump_If_False`).

**Верификация**: 7 e2e-тестов (Число со скользящим `_`, Строка с
биндер-catchall, Булево БЕЗ `_` exhaustive, литерал внутри
Constructor-подшаблона, 3 негативных — отсутствующий catch-all для
Число, непокрытое значение Булево, type mismatch литерала против
subject). `odin test ./core` — 130/130 (0 регрессий). native/lsp/wasm
чисты.

---

### Стадия 30 ✅ — деструктуризация в `пер`/`конст`

**Статус**: реализована сразу вслед за Стадией 29 (литеральные шаблоны в
`выбор`) — тот же разговор, естественное продолжение "паттерны везде".

**Что реализовано**: две формы, обе позиционные (без wildcard/биндера —
это НЕ `Pattern`-грамматика `выбор`, вариант всегда ровно один, ничего
исчерпывающе проверять не нужно):
- `пер (a, b) = кортеж` — тупл-деструктуризация, по позиции элемента.
- `пер Тип(a, b) = значение` — структурная, по ПОРЯДКУ ОБЪЯВЛЕНИЯ полей
  (тот же принцип, что у обычного позиционного конструктора `Тип(1, 2)`).

`конст (a, b) = ...` тоже работает — `is_const` пробрасывается на КАЖДОЕ
извлечённое имя, переприсваивание любого из них паникует так же, как
обычный `конст` (Стадия 27) — бесплатно, механизм уже общий.

**Компиляция без нового опкода**: RHS вычисляется один раз во временный
слот, затем `.Get_Property`(i) + `.Set_Local` на каждое имя — ТОТ ЖЕ
приём, что for-in уже применяет для `для (a, b) в ...` (Стадия 23,
`compile_for_in_stmt`, ветка `len(names_slots) > 1`) — тупл и структура
оба `Aggregate_Value`, числовой `.Get_Property`-индекс работает
одинаково для обоих без разбора кейсов в компиляторе.

**Механизм** (та же форма, что `For_In_Stmt.names`/`for_in_names_syms`,
только на `Let_Stmt`):
- `core/parser.odin` — `Let_Stmt` получил `names: [dynamic]string` +
  `destructure_type: string` (пусто = тупл, иначе — имя типа структуры);
  `parse_let_stmt` разбирает `(a, b)` сразу после `пер`/`конст`
  (тупл) или `Ident(a, b)` (структура — Ident, за которым сразу `(`, без
  пробела-чувствительности, никакой неоднозначности с обычным `пер x =
  вызов(...)`, т.к. проверка идёт на позиции ИМЕНИ БИНДИНГА, не значения).
- `core/resolver.odin` — новое поле `let_destructure_syms: map[Stmt]
  [dynamic]Symbol_Id`; `resolve_stmt`'s `Let_Stmt`-кейс регистрирует
  символ на КАЖДОЕ имя, если `s.names` непусто.
- `core/type_cheker.odin` — новая `infer_let_destructure_stmt`: тупл-
  ветка требует `value_type.kind == .Tuple` + совпадение длины; структур-
  ветка требует `value_type.kind == .Struct && value_type.name ==
  s.destructure_type` + совпадение числа полей — типы каждого имени
  берутся позиционно из `elements[i]`/`fields[i].type`.
- `core/compiler.odin` — `compile_statement`'s `Let_Stmt`-кейс: новая
  ветка на `len(stmt.names) > 0`, зеркалит `compile_for_in_stmt`'s
  multi-name extraction.
- `core/position.odin` — `collect_local_symbols_stmt` читает новую карту,
  чтобы LSP-автодополнение видело деструктурированные имена (тот же
  паттерн, что уже был для for-in).

**Верификация**: 5 e2e-тестов (тупл, структура, `конст`-immutability на
деструктурированном имени, 2 негативных — arity mismatch, wrong struct
type). `odin test ./core` — 135/135 (0 регрессий). native/lsp/wasm чисты.

---

### Стадия 31 ✅ — структурные конструктор-шаблоны в `выбор`

**Статус**: реализована сразу вслед за Стадией 30, тот же разговор —
запрос объединить `выбор` и деструктуризацию: `выбор точка { Точка(1,
x) -> ...; Точка(2, x) -> ...; Точка(_, _) -> ... }`.

**Что реализовано**: `Pattern_Constructor` (`Тип(...)`) — раньше работал
ТОЛЬКО на enum-вариантах — теперь работает и на структурах. Парсер БЕЗ
изменений (грамматика уже принимала `Тип(...)` как конструктор-шаблон,
литеральные под-шаблоны — со Стадии 29). Отличие от enum-варианта: у
структуры одна форма, не тег — совпадение по ИМЕНИ ТИПА (`pat.name ==
struct_type.name`), поля разбираются по ПОРЯДКУ ОБЪЯВЛЕНИЯ (тот же
принцип, что у `пер Тип(a, b) = ...`, Стадия 30, но здесь — полноценные
под-шаблоны: литерал/`_`/биндер/вложенный конструктор на каждом поле,
не только имена).

**Exhaustiveness — асимметрия с enum**: у структуры нет тегов для
per-variant coverage-массива. Ветка `Тип(...)`, все под-шаблоны которой
— `Wildcard`/`Binder` (например `Точка(_, _)`), ПОЛНОСТЬЮ покрывает
структуру целиком — эквивалентна голому `_`/биндеру: становится
`catch_all`, обязана быть последней. Ветка с частично сужающими
под-шаблонами (`Точка(1, x)` — первое поле пришпилено литералом) НЕ
покрывает ничего сама по себе — как и `Число`/`Строка` (Стадия 29), без
финальной catch-all ветки — Type Error.

**Компиляция без нового опкода**: `.Struct_Constructor` (новый
`Match_Arm_Kind`, параллельный `.Constructor`) пропускает `.Match_Tag`
целиком (нечего сравнивать — одна форма) и сразу распаковывает поля
через `.Get_Property` (тот же опкод, что и `.поле`, и что уже применяет
пер-деструктуризация Стадии 30) + рекурсивный `compile_pattern` на
каждое под-полe.

**Известное консервативное упрощение (унаследовано от Стадии 25/29, не
новое)**: вложенный `.Struct_Constructor`/`.Constructor`-под-шаблон
ВСЕГДА считается "не покрывающим целиком" родительскую ветку, даже если
САМ ПО СЕБЕ этот под-шаблон исчерпывающий (например
`Событие.Клик(Точка(_, _))` — внутренний `Точка(_, _)` покрывает ВСЕ
точки, но exhaustiveness-чекер всё равно требует ветку `Событие.Клик`
покрытой отдельно, не выводит это из вложенного покрытия). Та же
консервативная аппроксимация, что уже была у вложенных `.Literal`/
`.Constructor` под-шаблонов до этой стадии — не регрессия, сознательно
не усложняется рекурсивным выводом.

**Файлы**: `core/type_cheker.odin` (`Match_Arm_Kind.Struct_Constructor`,
`classify_pattern`'s `Pattern_Constructor`-кейс — новая struct-ветка
ПЕРЕД существующей enum-веткой, `infer_match_expr` — gate расширен на
`.Struct`, `check_match_coverage` — новый `case .Struct_Constructor`
плюс struct-specific "нужен catch-all" сообщение в конце);
`core/compiler.odin` (`compile_pattern` — новый `.Struct_Constructor`-
кейс).

**Верификация**: 4 e2e-теста (полный пример из запроса — 3 ветки с
литералом+catch-all; 3 негативных — отсутствующий catch-all, неверное
имя типа структуры, fully-covering ветка не последняя). `odin test
./core` — 139/139 (0 регрессий). native/lsp/wasm чисты.

---

### Стадия 32 ✅ — `Целое`: отдельный целочисленный тип

**Статус**: реализована по явному запросу — новый `Type_Kind.Integer`
(`TY_INT`) рядом с существующим `Число` (`TY_NUM`), НЕ переименование.
На рантайме то же f64-представление, что и `Число` — нет отдельного
`Value`-варианта, различие целиком на уровне типов, компилятор решает
опкод по `ctx.tc.node_types`.

**Литералы — Число по умолчанию, Целое только явно**: первый проход
сделал ровно наоборот (литерал по умолчанию Целое, расширение до Число
в Число-контексте через `check_expr`) — вызвал массовую регрессию
(десятки тестов), т.к. `check_expr` покрывает не все места, где
typechecker сравнивает типы (implicit return через `unify_types`,
enum-варианты, join-точки `если`/`выбор`). Обсуждался proper fix
(InferVar с deferred default, mirrors Haskell/OCaml literal defaulting)
— признан architecturally cleaner, но избыточной сложностью для узкого
выигрыша; выбран простой откат: **литерал всегда Число**, Целое
достижим только через явный Целое-контекст (аннотация/поле/параметр).
`check_expr` получил кейсы для `Number_Expr`/`Unary_Expr`(унарный
минус)/`Binary_Expr`(+/-/* — нужно для составных выражений вроде
`длина(x) - 1` в Целое-контексте, где ни один операнд сам по себе не
литерал-по-месту), `widen_num_literal_to_int` — симметричный helper для
бинарных операторов между операндом типа Целое и литералом-соседом
(`x + 5` при `x: Целое`).

**`/` и `%` только для Целое-семантики отличаются от Число**: `/` на
`Целое`/`Целое` — усечение к нулю (не флор-деление Python, `-7/2 = -3`,
как C/Rust/Go — компилятор эмитит новый опкод `.Int_Divide` вместо
`.Divide`, выбор опкода — по статическому типу операнда, т.к. рантайм
не отличает Целое/Число). `%` — новый оператор (токен `.Percent`,
`Int_Divide`/`Modulo` — новые VM-опкоды), только для Целое, паникует на
делении на ноль так же, как `/`.

**Индекс массива/строки — Целое строго** (по отдельному запросу в этом
же раунде): `infer_index_expr` требует `TY_INT`, не `TY_NUM`. Каскадом
это потребовало сделать Целое всё, что естественно участвует в
индексации:
- `длина(...)`/`.длина()` (массив/карта/строка) → `Целое`.
- `массив.получить(индекс, ...)`/`.есть(индекс)` → индекс `Целое`.
- числовой диапазон `для i = A по B цикл` — счётчик и граница `B`
  желаются Целое (парсер добавляет `: Целое`-аннотацию синтетическим
  `Let_Stmt`'ам в `parse_for_range_stmt_into`).
- `строки.срез`/`строки.найти` (builtin) — позиционные параметры и
  результат `найти` → `Целое`.
- новый builtin `строки.из_целого(Целое) -> Строка` (аналог
  `из_числа`, panos не имеет overloading — `Content-Length`-подобный
  код в `http.ps` иначе не мог бы напечатать длину).
- `is_valid_map_key_type` — забытый кейс, `Целое` не считался валидным
  ключом карты, поправлено заодно.

**Блайндспот, найденный по ходу**: синтетический `Type_Node` в парсере
собирался как `&Type_Ident{...}` (composite literal address-of) —
в Odin это стековая переменная, а не heap-аллокация; указатель
переживал возврат из `parse_for_range_stmt_into` и указывал на
освобождённый стек-фрейм → segfault при первом чтении поля `.name` в
резолвере (воспроизводилось на любом `для X = A по B цикл`). Поймано
не тестом, а ручным прогоном — `odin test ./core` в момент бага
не зависал, а МОЛЧА не завершался (уходил в бесконечный lup где-то в
crash-handler'е), что выглядело как "тесты стали медленными" — заняло
время отличить настоящий hang от медленного вывода. Фикс: `new
(Type_Ident)` + явное присваивание полей, как везде в парсере.

**Стандартная библиотека обновлена под индекс-обязан-быть-Целое**:
`std/коллекции.ps` (`отсортировать` — счётчик `i` теперь `: Целое`),
`std/кодирование/json.ps` и `std/кодирование/toml.ps` (`Токенизатор.поз
/.длина` теперь `Целое`, `.элемент(индекс: Целое)`), `std/сеть/http.ps`
(локальная `найти` теперь Целое-signature, счётчики позиций), `test.ps`
(массив/карта-примеры и числовой диапазон — явные Целое-аннотации, плюс
новая `проверка_целых()`), `docs/src/language/basic-types.md` (новый
раздел «Число и Целое»), `collections.md`/`control-flow.md` (примеры
поправлены под Целое-длину/-счётчик).

**Файлы**: `core/token.odin` (`.Percent`), `core/lexer.odin` (`%` →
`.Percent`), `core/parser.odin` (`infix_bp` для `%`, `mk_type_ident_int`
+ Целое-аннотация в `parse_for_range_stmt_into`), `core/type_cheker.odin`
(`Type_Kind.Integer`/`TY_INT`, `check_expr`'s
`Number_Expr`/`Unary_Expr`/`Binary_Expr`-кейсы, `widen_num_literal_to_int`,
`last_block_expr` + widening в `check_function_body`/`infer_if_expr`/
`infer_match_expr` join-точках, `infer_binary_expr`'s все арифметика/
сравнение/равенство-кейсы, `infer_unary_expr`, `infer_index_expr`,
`is_valid_map_key_type`, `resolve_variant_ctor`, длина-related builtin
и array/map-методы), `core/compiler.odin` (`.Int_Divide`/`.Modulo`
опкоды, `/`-кейс выбирает опкод по `ctx.tc.node_types[e.left]`),
`core/vm.odin` (`.Int_Divide`/`.Modulo`-хэндлеры, `строки::из_целого`),
`core/stdlib.odin` (`строки::срез`/`строки::найти` → Целое-параметры,
`строки::из_целого` — новая запись).

**Известное ограничение (сознательно, отложено)**: НЕТ неявной коэрсии
между уже типизированными значениями `Число`/`Целое` — только литералы
"расширяются" под контекст. Explicit cast между ними — будущая задача.
Никакой ширины/знаковости (i8/u32/i64 и т.п.) — только один
целочисленный тип, как и `Число` — один тип с плавающей точкой.

**Верификация**: `odin test ./core` — 139/139 (0 регрессий,
переписаны под Целое 5 существующих e2e-тестов длина/индекс-related).
native/lsp/wasm сборки чисты. `test.ps`, `test_toml.ps`, `test_http.ps`
и все 4 сетевых/кодирующих fixture'а (`collections_fixture_main.ps`,
`flags_fixture_main.ps`, `json_fixture_main.ps`,
`http_url_fixture_main.ps`) — вручную прогнаны, ноль diagnostics.

---

### Стадия 33 ✅ — Bounded traits: trait bounds на type-параметрах generic-функций

**Статус**: реализована по явному запросу. Мотивирующий кейс —
`std/коллекции.ps`'s `отсортировать`, берущая явный компаратор-лямбду
вместо `<`, т.к. до этой стадии `T` внутри `функ f[T](...)` был голым
`InferVar` без метаданных — тело generic-функции типизируется РОВНО
ОДИН РАЗ, абстрактно, независимо от call site'ов, и `x < y` при `x, y:
T` не мог резолвиться (нет способа узнать, реализует ли T
Сравниваемое).

**Согласовано (grilled, три раунда)**: bound-синтаксис — несколько
интерфейсов через `+` в одном `[T: A + B]`; scope — ТОЛЬКО generic-
функции (не структуры/интерфейсы — `Struct_Decl`/`Interface_Decl.
type_params` не изменены); диспатч — **мономорфизация** (не
рантайм-диспатч по type-тегу — обсуждался и отклонён как отдельная
архитектурная затея, ощутимо больше по объёму нового рантайм-
механизма) — тело компилируется ОТДЕЛЬНО под каждую конкретную
комбинацию type-параметров, встреченную на call site'ах; `Число`/
`Целое`/`Строка`/`Булево` реализуют "родные" bound'ы
(Сравниваемое/Складываемое и т.п.) даже без impl-блока — иначе `T:
Сравниваемое` отказал бы в вызове с T=Число, хотя `<` на числах и так
работает нативным хардкодом.

**Синтаксис**: `функ f[T: Интерфейс1 + Интерфейс2, U](...)` —
`Function_Decl.type_param_bounds: map[string][dynamic]string`, новая
`parse_function_type_params` (используется ТОЛЬКО `parse_function`,
общий `parse_type_params` для Struct/Interface не тронут).

**Резолв bound'ов**: `Type.required_interfaces: [dynamic]^Type` — новое
поле, непусто только у decl-param `InferVar` с bound'ом.
`make_decl_type_params` резолвит имена интерфейсов тем же путём, что
`resolve_type_node` резолвит голый `Type_Ident` (module-scope lookup),
проверяет `kind == .Interface`.

**Единая точка проверки — `type_satisfies_interface`**: для decl-param
InferVar сверяет `required_interfaces`; для конкретных типов —
`primitive_satisfies_interface` (Число/Целое/Строка → Сравниваемое,
Число/Целое → арифметика, БЕЗ Равнозначное — opt-in override уже
всегда доступного структурного `==`, универсальный fallback тут дал бы
ложный sugar-путь на структуры без impl, живой баг, пойманный тестами
на этапе разработки) поверх существующего `implements_prelude_
interface`. Заменяет 5 существующих sugar-гейтов в `infer_binary_expr`
(kind-гейт расширен на `.InferVar`).

**Абстрактный проход и рекурсия**: тело bounded generic-функции
ВСЁ ЕЩЁ типизируется один раз абстрактно (как любой generic) — но
теперь может содержать вызовы ДРУГИХ (или себя — рекурсия) bounded
generic-функций, для которых конкретный тип НЕ выводим на этом
проходе. Новый ambient-флаг `ctx.in_abstract_generic_body` (тот же
save/restore паттерн, что `current_type_params`) отличает "рекурсия
внутри абстрактного шаблона — не диагностика" от "вызывающий код
реально не смог вывести тип — настоящая ошибка".

**Мономорфизация — AST-clone + fixed-point driver**: честной
мономорфизации без дублирования 100% typecheck/compile-логики не
сделать без клонирования — `ctx.node_types`/`ctx.call_infos` ключуются
ПО УКАЗАТЕЛЮ узла, повторный typecheck ТЕХ ЖЕ узлов с разным T
перезаписал бы результат предыдущей инстанциации. Новый
`core/ast_clone.odin` — `clone_expr`/`clone_stmt`/`clone_type_node`
(19+7+6 вариантов, механически, взаимно рекурсивно). Новый
`core/monomorphize.odin`:
- `ctx.generic_call_instantiations: map[Expr][dynamic]^Type` — Call_Expr
  вызова bounded generic-функции → резолвленные конкретные типы (пишет
  новый `infer_bounded_generic_call`, отдельная ветка от обычного
  `infer_call_expr`-пути — своя `instantiate_scheme_with_subst`,
  отдающая subst-карту, без которой не восстановить, какой свежий
  InferVar соответствует какому ИМЕНОВАННОМУ type-параметру).
- `build_instantiation_key` — человекочитаемый ключ `"f$Число"`/
  `"f$Точка,Строка"` (в отличие от `generic_instance_cache`'s
  pointer-based ключа — этот реальный `registry`-ключ).
  `monomorphize_one` клонирует тело, резолвит клон в scope того же
  модуля (`resolve_function_body` напрямую, тот же ctx.res, что и весь
  остальной pipeline), типизирует с T, подставленным в конкретный тип
  НАПРЯМУЮ (`ctx.current_type_params[name] = concrete`, БЕЗ единого
  нового InferVar — клон typecheck-целиком идёт по существующим,
  немодифицированным путям, неотличим от обычной non-generic функции),
  компилирует и кладёт под ключ в registry. `monomorphize_program` —
  fixed-point driver (снимает снимок необработанных ключей на каждой
  итерации вместо мутации map во время обхода — typecheck клона сам
  добавляет НОВЫЕ записи в `generic_call_instantiations`, рекурсия).

**Компилятор**: `compile_program` зовёт `monomorphize_program` МЕЖДУ
pass 1 (hoisting обычных функций/методов) и pass 2 (компиляция их тел)
— клоны могут ссылаться указателем на `Compiled_Function` обычных
методов (напр. `.сравнить()`) уже на этапе hoisting'а (skeleton
существует, тело ещё нет — не проблема, указатель стабилен); ДО
mono — обычные функции не нашлись бы в registry (первая версия
ошибочно ставила mono ПЕРЕД pass 1 целиком — живой баг, пойман сразу
на первом struct-sugar тесте). Bounded generic `Function_Decl`
исключены из pass 1/2 (шаблон никогда не компилируется напрямую).
Call site (`^Call_Expr`-кейс в `compile_expr`) — если
`ctx.tc.generic_call_instantiations[expr]` непусто, ключ инстанциации
вместо обычного `symbol_registry_key`.

**Побочная находка — серьёзный pre-existing баг, не регрессия этой
стадии**: `resolve_program` создавала `Module` как СТЕКОВЫЙ
композитный литерал (`module := Module{...}`), а `Symbol.module`
хранит `^Module` на него — dangling pointer сразу после возврата из
`resolve_program`. Молчал годами, т.к. ничего раньше не читало
`Symbol.module` так поздно в pipeline'е; `monomorphize_one` — первый
код, дочитывающийся до `symbol_at(...).module.path` на этапе
КОМПИЛЯЦИИ (стек уже многократно переиспользован другими вызовами) —
`new_symbol`'s `fmt.tprintf("%s::%s", module.path, name)` падал с
memmove-корраптом на "правильном" (в стандартном main.odin с
custom-арена-аллокатором) прогоне, но воспроизводился 100% стабильно
вне его. Тот же класс бага, что stack-escape в
`parse_for_range_stmt_into` (Стадия 32) — исправлено: `new(Module)`,
как везде в `module_loader.odin`.

**Файлы**: `core/parser.odin` (`type_param_bounds`,
`parse_function_type_params`), `core/type_cheker.odin`
(`required_interfaces`, `make_decl_type_params` bounds-параметр,
`type_satisfies_interface`/`primitive_satisfies_interface`, 5
sugar-гейтов, `ctx.generic_call_instantiations`/`in_abstract_generic_
body`, `infer_bounded_generic_call`, `instantiate_scheme_with_subst`),
`core/ast_clone.odin` (новый), `core/monomorphize.odin` (новый),
`core/compiler.odin` (`compile_program` порядок pass'ов + mono, call
site codegen), `core/resolver.odin` (`resolve_program`'s `Module`
heap-allocated fix).

**Известное ограничение (сознательно, отложено)**: только generic-
ФУНКЦИИ — bounded generic-структуры/интерфейсы (`тип Коробка[T: X] =
структура ...`) вне scope, отдельная задача при реальной нужде.

**Верификация**: 4 новых e2e-теста (primitive+struct dispatch в одной
программе с разными скомпилированными версиями; негативный без impl;
multi-bound с недостающим одним интерфейсом; рекурсия). `odin test
./core` — 143/143 (0 регрессий). native/lsp/wasm сборки чисты.

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

**WASM-спайк (браузерное демо) — сделано, v1 узкий**: `core` компилируется
для `-target:js_wasm32` и реально исполняет panos-скрипты в браузере
(`wasm/main.odin` + `demo/` — `index.html`+официальный `odin.js`-рантайм
Odin, вывод рендерится в HTML-консоль через `odin_env.write`, без единой
строчки собственного WASM-парсинга памяти под print). Главный блокер был
не архитектурный, а платформенный: `core:os`/`core:net` падают
compile-time panic'ом при простом импорте под `js_wasm32` (не просто
отсутствующие символы) — решено `#+build !js`/`#+build js` расщеплением
по образцу `core:fmt`'s `fmt_os.odin`/`fmt_js.odin` (`compiler.odin`
File_Value/Socket_Value, `vm.odin` фс/сеть/стдин-builtin'ы,
`module_loader.odin`/`resolver.odin` файловый импорт). Плюс отдельный
баг: `runtime.heap_allocator()` (raw malloc-обёртка, используется в
gc.odin/interner.odin) не реализован на js/wasm (компилируется, падает в
рантайме при первом вызове) — `vm_heap_allocator()` (gc.odin) выбирает
`runtime.default_wasm_allocator()` на js через `when ODIN_OS == .JS`.
`core/pipeline.odin` (новый, не test-файл) — inline-pipeline без
файлового I/O, вынесен из e2e_test.odin (тот теперь `#+build !js` —
core:testing не собирается под js в этом тулчейне), переиспользован и
тестами, и WASM-входом.

**Вне scope v1** (сознательно, браузер физически не может): файловый
`импорт` (std/математика и т.п.), `фс`/`сеть` builtin'ы, блокирующий
стдин (`ввод_вывод.прочитать_строку`) — все паникуют понятным
"недоступно в браузере" вместо тихого игнора. `ос.аргументы`/
`ввод_вывод.печать`/`ввод_вывод.строка`/`сеть.кодировать_url` работают
(os/net-агностичны и так). Следующий шаг, если демо стоит доводить до
продакшена: embed стандартной библиотеки в WASM-бинарь через Odin's
`#load` (вместо файлового чтения) — тогда `импорт математика` и т.п.
заработает и в браузере.

**Важный факт о текущей семантике** (не убрано, не отложено — найдено
при grilling Стадии 22/23, зафиксировано, чтобы не потерялось):
**структуры в panos — reference semantics, не value semantics**.
Присваивание/передача структуры копирует УКАЗАТЕЛЬ, не поля — `Value`
(compiler.odin:75) union из ПОИНТЕРОВ на всё, кроме `f64`/`bool`
(`^Aggregate_Value`, `^Array_Value`, `^Panos_String` и т.д.).
Подтверждено живым тестом: `пер b = a; b.x = 99; a.x` печатает `99`.
Значит panos-структуры ведут себя как объекты Python/Java (alias по
умолчанию), НЕ как структуры Go/Rust/Swift (копия по умолчанию) — это
НЕ баг, но источник классических aliasing-сюрпризов (тот же класс, что
"mutable default argument" в Python), нигде явно не документировано.
Напрямую формирует дизайн будущей Стадии 23's "Копируемое" (см. там) —
это не нишевый "скопировать вложенный Array/Map", а единственный способ
вообще получить независимую копию любой структуры.

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
