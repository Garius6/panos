# Panos — Задачи

**Текущая стадия**: готовы 0, 1, 2, 3, 6, 7, 10, 11, 12, 13, 14, 15, 16,
17, 18, 19, 20, 21, 22 (10-21 — вне очереди, 22 — Сравниваемое/
Равнозначное operator sugar), 5 частично (Symbol_Id + LSP
completions/references/rename; Type_Id отложен). Следующие
разблокированные: 4 (FFI-A), 8 (FFI-B, требует 1 ✓ — finalizers теперь
возможны). 23 ЗАКРЫТА ПОЛНОСТЬЮ ✅ (Печатаемое/Арифметика/Копируемое/
Итерируемое; По-умолчанию и Хешируемое выброшены — см. ниже, обе без
реального потребителя под интерфейсом). 28 (generic-интерфейсы) ✅.
24 (lightweight
processes, Elixir/Akka-style actor model — дважды пересмотрена, CSP-каналы
заменены на actor model) — ключевые решения grilled и подтверждены,
touch-точки требуют Explore до плана. 25 (интерфейсы для перечислений) ✅.
26 (`panos mod` — встроенный пакетный менеджер, go mod style) — ключевые
решения grilled (три раунда), touch-точки требуют Explore. 29-44
ЗАКРЫТЫ ✅ (литеральные шаблоны в `выбор`, деструктуризация,
структурные конструктор-шаблоны, `Целое` — отдельный целочисленный
тип, bounded traits — мономорфизация generic-функций, рекурсивная
exhaustiveness для вложенных конструктор-шаблонов, именованные поля в
структурных шаблонах, именованные аргументы в вызовах, именованная/
частичная деструктуризация, monitor-примитив `наблюдать`/`получить_
сигнал` + изоляция крашей процессов, единая hard-reserved политика
зарезервированных слов, супервизия — `реализация Модуль.Интерфейс для
Тип` + `std/супервизор.ps` + restart-стратегии `ВсеЗаОдного`/
`ОстальныеЗаОдним` + kill-примитив `убить` + подключение `убить()` к
групповым рестартам супервизора + link-примитив `связать`). **Приоритет
(grilled)**: 24/26/4/8 — следующие кандидаты. Type_Id/SoA (остаток
Стадии 5) — отдельная перформансная задача без явного триггера.
**Roadmap**: [ROADMAP.md](ROADMAP.md)

Работа отслеживается через mkdnflow.nvim в Neovim. `<CR>` на строке
переключает состояние checkbox'а. Родительские элементы обновляются
автоматически.

## Легенда

- `- [ ]` — не начато
- `- [-]` — в работе
- `- [x]` — готово

Отменённые/отложенные задачи помечаются строкой `(отложено: причина)` без
изменения checkbox'а — так они видны в progress-view.

---

## Стадия 0 — Foundation cleanup

Refs: [ROADMAP §Стадия 0](ROADMAP.md#стадия-0--foundation-cleanup),
[type-checker analysis](specs/001-adt-pattern-matching/reviews/type-checker-analysis.md).

Цель: −209 строк type-checker'а, устранение дублей и утечек памяти. Zero
risk, разблокирует всё последующее.

### Волна 1 рефакторинга type-checker'а

- [x] P2 — helper `resolve_variant_ctor` (унифицировать 3 места
      Enum_Variant construction, `type_cheker.odin:1523-1772`)
- [x] P3 — `variant_index: map[string]int` в `Type` + helper
      `variant_index(enum_type, name) -> (int, bool)`
- [x] P5 — synth cache `Type_Ctx.synth_enum_cache: map[^Type]^Type` +
      `synth_enum_view(ctx, base)`
- [x] P12 — убрать двойные `prune_type(prune_type(x))` вызовы
- [x] P13 — `BASE_TYPES` map + добавить `Никогда` (сейчас баг:
      `функ f() -> Никогда` падает)
- [x] P14 — убрать `Match_Arm_Info` wrapper, использовать `Pattern_Info`
      напрямую
- [x] P15 — унифицировать `variant_calls` + `variant_idents` в
      единый `variant_ctors: map[Expr]Variant_Ctor_Info` (включает P4-часть)

### Verification

- [x] `odin test .` — 38/38 тестов зелёные
- [x] `odin run . -- test.ps` — без регрессий
- [x] Type-checker строк ≤ 2150 (было 2359) — **не достигнуто**: итог
      2289 строк (−70). Дедупликация и утечки устранены как задумано,
      но добавленная инфраструктура (helper'ы, кэш, docstring'и)
      компенсировала часть экономии — расхождение с прогнозом отчёта
      (−209), не регрессия.

### Delivery

- [x] Коммит с русскоязычным описанием изменений — `3055f10`

---

## Стадия 1 — Runtime memory model (GC) ✅

Refs: [ROADMAP §Стадия 1](ROADMAP.md#стадия-1--runtime-memory-model-gc-2-недели).

Prerequisite: Стадия 0 закрыта. Разблокирует FFI-B (finalizers) и
long-running scenarios.

### Prerequisites

- [x] `^Panos_String` обёртка для runtime-строк — `{header: GC_Header,
      data: string}` (не `{bytes, len}` — переиспользует Odin `string` как
      backing, проще). Compile-time литералы идут через отдельный
      `perm_string()` (не регистрируется в GC — живут весь процесс)
- [x] Migration runtime-strings — конкатенация (`.Add`), `фс::прочитать`,
      `stdin`, срез строки по индексу, все builtin'ы

### Core GC

- [x] `GC_State` — не через `mem.Allocator` interface, как в исходном
      плане, а как явное поле `VM.gc: GC_State` с процедурами
      `gc_new(vm, $T)` — проще, не требует imitация Odin allocator vtable
      для 9 разных типов
- [x] `GC_Header` — упрощён до `{marked: bool}` (без `kind`/`size`/`next`
      intrusive-list полей): `all_objects: [dynamic]Value` — плоский
      список, Odin union уже несёт kind-информацию, intrusive linked list
      не нужен
- [x] `gc_new(vm, $T: typeid)` — параметрическая процедура с `when
      T == X` для диспетчеризации в free-list (см. ниже)
- [x] Value walker (`mark_value`) — exhaustive switch по всем 11
      вариантам (12-й будет compile error, не тихий пропуск)
- [x] Root walker (`mark_roots`) — `vm.stack` (покрывает и temporaries, и
      локали — `frame_pointer` индексирует в тот же стек), `protect_stack`
      (см. ниже), `vm.compiled_functions[*].constants`
- [x] Mark phase — рекурсивный, с cycle-guard через `marked`-флаг
      (циклические структуры не зацикливают mark; отдельного теста на
      cycle collection нет, но защита от бесконечной рекурсии — часть
      самого mark_value, не опциональна)
- [x] Sweep phase
- [x] Adaptive threshold (2x live bytes после каждого sweep) — грубое
      приближение: `.elements`/`.entries`/`.fields` содержимое в
      bytes_allocated не считается, только заголовки структур + байты
      строк (симметрично на alloc/free — иначе threshold дрейфовал бы)

### Архитектурное дополнение — object pooling (не было в исходном плане)

Первая версия (mark-sweep поверх голого `new()`/`free()`) прошла все
функциональные тесты, но **не прошла собственный checkpoint**: peak RSS
на CLI-прогоне линейно рос с числом итераций (164MB → 968MB на 1M → 6M
итераций), несмотря на то, что внутренний учёт GC (bytes_allocated,
live_objects) был идеально стабилен цикл к циклу. Причина — разрыв между
"logically freed" и "OS-visible память переиспользована": `free()`
возвращает блок в malloc, но под sustained churn ОС/malloc не гарантируют
быстрый reuse тех же страниц.

Исправлено free-list per типу (`GC_State.free_aggregates`,
`free_arrays`, ... `free_strings`) — `sweep()` не зовёt `free()` на
недостижимом объекте, а кладёт в пул (`pool_release`); `gc_new` сначала
пробует `pool_take` из пула. Для `.elements`/`.entries`/`.fields`
call-сайты в vm.odin (`Build_Aggregate`/`Array`/`Map`/`Variant`) переведены
с `= make([dynamic]Value, n)` на `resize(&obj.field, n)`, иначе
переиспользование backing-буфера теряло смысл. Результат: peak RSS стал
плоским — **7.65MB одинаково на 1M/3M/6M итераций** массивов. Для
string-heavy нагрузки (конкатенация в цикле) пока пул только заголовка
`Panos_String`, не самого byte-буфера переменной длины — рост памяти
есть, но не катастрофический (43MB → 158MB на 500k → 2M итераций);
полноценный size-class аллокатор для строк — задел на будущее, не сделан
(см. "Известные ограничения" ниже).

### Integration

- [x] Split allocator lifecycle — arena (`main.odin`) для parse/compile,
      `runtime.heap_allocator()` явно пином для всех GC'd аллокаций внутри
      gc.odin (тот же паттерн, что уже использован для `INTERNER` в
      interner.odin — Dynamic_Arena не поддерживает free() отдельных
      аллокаций)
- [x] Migration `new(X)` → `gc_new(vm, X)` в vm.odin — 17 сайтов
      (Aggregate/Array/Map/Error/Option/Result/Interface/Variant_Value)
- [x] `gc_protect`/`gc_unprotect` — обнаружен и закрыт реальный
      "lost roots during construction" баг: `Cast_Interface` снимал `agg`
      со стека, потом аллоцировал `Interface_Value` — в этом окне `agg`
      не был ни на стеке, ни встроен никуда; аналогично для
      `make_ok_result`/`make_error_result`/builtin'ов, конструирующих
      несколько GC-объектов подряд до финального push на стек

### Instrumentation

- [x] `gc_stats(vm)` — live_objects, bytes_allocated, collections_run,
      freed_last_run
- [x] `force_gc(vm)` — для тестов
- [ ] Verbose mode (env var/flag с логом каждой коллекции) — не сделан,
      не запрашивался; временная версия использовалась для отладки RSS-бага
      выше и была удалена

### Tests

- [x] Программа с миллионом allocation'ов в цикле — память не растёт
      (`test_gc_reclaims_garbage_in_loop`, `test_gc_keeps_reachable_data_alive`
      в e2e_test.odin, плюс ручная проверка `/usr/bin/time -l` на 1M/3M/6M
      итераций через CLI — см. выше)
- [ ] Циклические ссылки собираются (interface → self) — отдельного теста
      нет; mark_value защищён от бесконечной рекурсии по циклам
      (cycle-guard через marked-флаг), но explicit-cycle collection тест
      не написан
- [ ] Closure captured variables — N/A: у Panos пока нет захвата внешних
      переменных в лямбдах (`Lambda_Expr` компилируется как независимый
      `Compiled_Function` без upvalue-списка) — нечего тестировать
- [x] Все существующие тесты проходят (38 исходных + 2 новых GC-теста = 40/40)
- [x] Memory-tracker (`odin test ./core`) не показывает новых
      runtime-leaks относительно до-GC состояния

### Delivery

- [ ] Отдельные коммиты per major step — сделано одним коммитом (весь
      объём — Panos_String + GC core + object pooling — тесно связан,
      разбивка на sub-PR потребовала бы временных промежуточных состояний
      с непроходящими тестами)

---

## Стадия 2 — DOD Волна 1 + Diagnostic accumulation (готово, коммит `7659f8e`)

Refs: [ROADMAP §Стадия 2](ROADMAP.md#стадия-2--dod-волна-1--diagnostic-accumulation-15-недели).

Prerequisite: Стадия 0. Разблокирует LSP.

Архитектура: eager unify + `TY_POISON` (текущий подход), **не**
constraint-based generate-then-solve. Обсуждено и отклонено для этой
стадии — подробности [ROADMAP §Стадия 2](ROADMAP.md#стадия-2--dod-волна-1--diagnostic-accumulation-15-недели)
(раздел "Архитектурная развилка"). Constraint-based рассмотреть в
Стадии 7 (там он естественно нужен под let-generalization).

- [x] `Span {file_id: u16, start: u32, end: u32}` struct
- [x] Span в токенах
- [x] Span в AST-узлах — **43 struct'а, не ~15** (стек-план был занижен,
      см. подробную инвентаризацию перед реализацией)
- [x] `Interned :: distinct u32` + `String_Interner` — с mutex'ом и
      heap-allocator'ом (глобальный синглтон, `odin test` гоняет 10
      потоков параллельно, без синхронизации ловили гонку данных)
- [x] Migration `Ident_Expr.name`, `Symbol.name` на Interned. `Type.name`
      **осознанно не тронут** — используется и для equality lookup, и
      для печати в diagnostic-сообщениях; interning дал бы только
      resolve-боль без выигрыша (решение зафиксировано перед стартом)
- [x] `Diagnostic {severity, span, message}` struct (без отдельного поля
      `args` — message форматируется сразу в `report()`)
- [x] `Type_Ctx.diagnostics: [dynamic]Diagnostic`
- [x] `TY_POISON` тип для non-cascade error propagation
- [x] Migration `fmt.panicf` → `report(ctx, span, ...)` — 109 из 116
      сайтов в type_cheker.odin; 7 внутренних инвариантов (не
      user-facing, напр. рассинхронизация resolver/typechecker)
      остались panic'ами осознанно
- [x] `expect_diagnostic(t, diagnostics, expected)` + `typecheck_only(source)`
      test helper'ы в e2e_test.odin
- [x] Migration e2e-тестов на diagnostic vector — **не переписывали 9
      существующих `expect_assert`-тестов**, вместо этого добавили мост
      `panic_on_diagnostics` (паникует текстом первого diagnostic'а) —
      все прошли без изменений; `expect_diagnostic` доступен для новых
      multi-error тестов

---

## Стадия 3 — LSP MVP ✅

Refs: [ROADMAP §Стадия 3](ROADMAP.md#стадия-3--lsp-mvp-15-недели).

Prerequisite: Стадия 2.

- [x] LSP server skeleton (JSON-RPC 2.0 over stdio) — `lsp/lsp_transport.odin`
- [x] `initialize` / `shutdown` handshake
- [x] Full-reparse on `textDocument/didChange`
- [x] `textDocument/publishDiagnostics`
- [x] `textDocument/hover` — тип под курсором
- [x] `textDocument/definition` — go-to-def, **теперь и межфайловый**
      (см. "Граф импортов" ниже — изначально было known limitation MVP,
      закрыто позже по запросу пользователя)
- [x] ~~VS Code extension skeleton~~ — заменено на Neovim-интеграцию
      (`editors/nvim/`, filetype-детект + `vim.lsp.start()`) по прямому
      указанию пользователя вместо VS Code
- [x] Position mapping UTF-16 ↔ UTF-8 — `lsp/lsp_position.odin`
- [x] ~~E2E тесты через vscode-languageserver-testkit~~ — верифицировано
      кастомным Python JSON-RPC клиентом + headless Neovim 0.12 вместо
      vscode-инструментария (нет VS Code extension'а)

Архитектура: код разделён на `core/` (общий пакет — лексер/парсер/резолвер/
тайпчекер/компилятор/VM) и 2 независимых `package main` бинарника —
`panos` (интерпретатор, корень) и `panos-lsp` (`lsp/`). Изначально
планировался один бинарник с `--lsp` флагом, но Odin запрещает циклические
импорты между `main` и подпакетом, который импортирует `main` обратно —
двухбинарная схема снимает проблему.

### Граф импортов в LSP (пост-MVP, сделано по запросу пользователя)

Изначально каждый документ типизировался изолированно (`resolve_program`,
single-file, без разбора импортов) — реальный проект с `импорт X` либо
падал с "модуль не найден" (диск не проверялся), либо не резолвил
экспорты вовсе. Заменено на полноценный `core.Module_Graph` per документ:

- [x] `core.load_module_graph_with_overrides(entry_path, overrides)` —
      как `load_module_graph`, но модули, открытые сейчас как LSP-буферы,
      подставляются из памяти (`Module_Graph.source_overrides`) вместо
      чтения с диска — реагирует на несохранённые правки в
      импортированных файлах, а не только в текущем
- [x] `update_document` строит граф из ТЕКУЩЕГО документа + пересчитывает
      resolve/typecheck для каждого модуля в `graph.order` (топологический
      порядок, как в `main.odin`), не только для entry
- [x] go-to-definition резолвит символы через `graph.symbol_store`
      (общий на весь граф) — корректно прыгает в ДРУГОЙ файл, если символ
      объявлен в импортированном модуле
- [x] diagnostics публикуются per-file (`publishDiagnostics` на каждый
      файл графа, не только на entry) — включая зависимости, которые
      сейчас не открыты как отдельные документы, но резолвятся при
      прогоне графа (`LSP_Document.all_diagnostics`, не только entry's
      res_ctx/tc_ctx)
- [x] Любое изменение (`didOpen`/`didChange`) пересчитывает ВСЕ открытые
      документы, не только изменившийся — если открыты и `main.ps`, и
      импортируемый им `util.ps`, правка в `util.ps` (даже несохранённая)
      немедленно отражается на diagnostics `main.ps`
- [x] Найден и исправлен попутный баг: `resolve_existing_import_path`
      писал debug-`fmt.printf` в STDOUT — раньше не мешало (CLI, и LSP
      никогда не резолвил импорты), но ломало JSON-RPC framing, как
      только LSP реально стал разбирать графы импортов
- [ ] find-references/rename по-прежнему сканируют usages только в
      текущем документе (`doc.usages`), не по всему графу — символ,
      объявленный в текущем файле и используемый в ДРУГОМ открытом файле,
      найдётся не полностью. Определение (go-to-def) резолвится корректно
      в любом случае, т.к. использует общий symbol_store

Verification: ручной multi-file сценарий (`main.ps` импортирует `util.ps`)
через Python JSON-RPC клиент — go-to-definition из main.ps в util.ps,
diagnostics корректно пусты при валидном импорте, корректно показывают
"не экспортирует" при переименовании экспорта в util.ps БЕЗ сохранения на
диск, и корректно очищаются при отмене правки. `odin test ./core` 40/40
без регрессий.

---

## Стадия 4 — FFI фаза A: raylib demo

Refs: [ROADMAP §Стадия 4](ROADMAP.md#стадия-4--ffi-фаза-a-raylib-demo-3-дня)
— расширено 16.07.2026 конкретными touch-точками для самостоятельной
реализации (не Explore-агентом, вручную).

Prerequisite: нет содержательного, но полезно сначала прочитать
`core/stdlib.odin`/`core/vm_io_native.odin` — эта стадия копирует их
шаблон (`is_builtin_module_name`/`builtin_export_type`/
`ensure_builtin_module` + `call_builtin_io`-подобная функция) почти
без изменений, только для нового модуля `графика`.

Не настоящий FFI (см. Стадию 8) — статические Odin-биндинги, вручную
завёрнутые в один модуль. **Решить перед стартом**: системный raylib
(`brew install raylib` + `foreign import "system:raylib"`) vs vendored
(`external/raylib/`, C-компилятор в пайплайне сборки) — raylib НЕ
vendored в репозитории сейчас.

- [ ] `core/raylib_bindings.odin` (`#+build !js` — обязательно, иначе
      WASM-сборка попытается слинковать raylib) — foreign import +
      Odin-сигнатуры нужных функций (не все ~50 сразу — минимум для
      pong: InitWindow/CloseWindow/WindowShouldClose/BeginDrawing/
      EndDrawing/ClearBackground/DrawRectangle/DrawCircleV/IsKeyDown/
      GetFrameTime)
- [ ] `core/vm_graphics_native.odin` (`#+build !js`) — `call_builtin_
      graphics`, по образцу `vm_io_native.odin:101`'s `call_builtin_io`,
      подключить в `call_builtin` (vm.odin:753)
- [ ] `core/stdlib.odin` — 4 точки: `is_builtin_module_name` (добавить
      "графика"), `builtin_export_type` (case на каждую функцию),
      `ensure_builtin_module` (новая ветка), готовые хелперы
      `builtin_function_type_1/2/3` (для функций с 4+ параметрами
      понадобится `_4`+ по аналогии)
- [ ] Vector2/Color БЕЗ новых Type_Kind — Vector2 = обычный panos-тупл
      `(Число, Число)`, распаковка через `.Get_Property` в
      graphics-обёртке; Color — тупл `(Число×4)` или маленькая
      panos-структура, объявленная прямо в демо-программе
- [ ] Demo: pong / snake в новом каталоге `demos/` (сейчас не
      существует)
- [ ] Проверить `just build-wasm` не ломается (графика недоступна в
      браузере, как `фс`/`ос`/`сеть` сейчас)
- [ ] README gif с демо

---

## Стадия 5 — DOD Волна 2 + LSP расширение (частично)

Refs: [ROADMAP §Стадия 5](ROADMAP.md#стадия-5--dod-волна-2--lsp-расширение-2-3-недели).

Prerequisite: Стадия 3.

- [x] `Symbol_Id :: distinct u32` + `Symbol_Store` — реализовано как
      `[dynamic]Symbol` (AoS) + индекс, а не колоночный SoA из ROADMAP
      (columns: names/kinds/scope_ids/...). Даёт стабильные ID и дешёвые
      Symbol_Id→usage таблицы (главная цель LSP-фич ниже) без риска
      переписывать unification-семантику; полный SoA отложен вместе с
      Type_Id (см. ниже) как чисто перформансная доработка
- [x] Migration `^Symbol` → `Symbol_Id` в resolver/type_cheker/compiler/lsp
      (INVALID_SYMBOL sentinel = Symbol_Id(0), симметрично Interned(0))
- [ ] `Type_Id :: distinct u32` + `Type_Store` SoA — **отложено**. `Type` —
      рекурсивная структура с pointer-identity семантикой (unify через `==`,
      mutable `binding` для InferVar union-find, глобальные синглтоны
      TY_NUM/TY_POISON), используется в 150+ местах 2700-строчного
      type_cheker.odin. Перевод на ID-store — не переименование, а
      переписывание модели вывода типов. Не блокер для LSP-фич ниже
      (completions/references/rename нужен только Symbol_Id)
- [ ] Migration `^Type` → `Type_Id` — отложено вместе с предыдущим пунктом
- [x] LSP: `textDocument/completion` — глобальные символы модуля + параметры
      и локали объемлющей функции/метода (`lsp/lsp_position.odin:
      collect_local_symbols`). MVP: без точной блочной видимости по
      позиции курсора (over-suggest — предлагает локали из непройденных
      веток if/match, но не даёт ложных отрицаний)
- [x] LSP: `textDocument/references` через `Symbol_Id -> [dynamic]Span`
      (`lsp/lsp_server.odin: build_usages`, один проход по node_symbols
      при каждом реparse'е документа)
- [x] LSP: `textDocument/rename` через WorkspaceEdit — та же usage-таблица,
      что и references. Как и go-to-definition: single-file, без графа
      импортов (межфайловый rename не входит в MVP)

Verification: `odin test ./core` 38/38, `test.ps` без регрессий, both
binaries (`panos`, `panos-lsp`) билдятся чисто, JSON-RPC round-trip
проверен Python-клиентом на completion/references/rename.

---

## Стадия 6 — TC Волна 2 (готово, коммит `fbbc5be`)

Refs: [ROADMAP §Стадия 6](ROADMAP.md#стадия-6--tc-волна-2-1-неделя).

Prerequisite: Стадия 5 — **не закрыта, сделано вне очереди** по
явному запросу (нарушает правило приоритизации ROADMAP §6.1). Учесть
при планировании Стадии 5 (Symbol_Id/Type_Id): split `infer_expr`
из P1 придётся тронуть повторно при миграции на ID-based символы.

- [x] P1 — split `infer_expr` на per-case процедуры (854 строки →
      15 отдельных `infer_X_expr` + ~15-строчный диспатчер)
- [x] P4 — унификация 6 side-tables в `call_infos: map[Expr]Call_Info`
      с тегом `Call_Kind` (было: is_constructor, method_calls,
      interface_calls, collection_calls, builtin_calls, variant_ctors)
- [x] P6 — data-driven `builtin_constructor_type` (`BUILTIN_CTORS`) +
      `standard_method_type` (`OPTION_METHODS`, `RESULT_METHODS`)

Verification: `odin test .` 38/38 зелёные, `odin run . -- test.ps` без
регрессий. Line count не сокращён (2359→2442) — P4/P6 добавляют
табличную инфраструктуру взамен дублирования, экономия не в строках.

---

## Стадия 7 — Generics

Refs: [ROADMAP §Стадия 7](ROADMAP.md#стадия-7--generics-2-3-недели).

Prerequisite: Стадия 6.

Архитектура: переход на constraint-based inference (generate constraints
→ solve batch'ем) вместо текущего eager unify — естественный субстрат
для `generalize`/`instantiate` (let-polymorphism). Error-sentinel
(TY_POISON-эквивалент) переезжает в solver, но не исчезает — см.
[ROADMAP §Стадия 7](ROADMAP.md#стадия-7--generics-2-3-недели)
(раздел "Архитектурное решение").

- [x] Constraint generation pass (`Equal(t1, t2)` и т.п., без solve) —
      ограниченный scope (только join-точки: если/иначе, выбор-ветки,
      элементы массива/соответствия-литералов), см. заметку "по
      constraint generation/solver" в ROADMAP §Стадия 7
- [x] Constraint solver (batch unification над накопленными
      constraint'ами) — тот же ограниченный scope, см. там же
- [x] Phase A: implicit rank-1 для лямбд — сделано на eager-unify, БЕЗ
      constraint-based (см. заметку в ROADMAP §Стадия 7 "Заметка по Phase A")
- [x] Phase B: `функ имя[T](x: T) -> T` — переиспользует Type_Scheme/
      symbol_schemes из Phase A, инстанциация на вызове не потребовала
      правок в infer_call_expr (см. заметку в ROADMAP §Стадия 7)
- [x] Phase C: generic struct — только структуры (интерфейсы отложены,
      сравнимы по объёму с Phase E); добавлен generic_instance_cache
      (identity-канонизация инстанциаций, см. заметку в ROADMAP §Стадия 7)
- [x] Phase D: generic ADT — вскрыл и починил 3 бага по пути (identity
      unify для .Enum, кэш-ключ конструктора structs по порядку полей
      вместо заголовка, SIGSEGV на самоссылающихся generic-типах), см.
      заметку в ROADMAP §Стадия 7
- [x] Phase E: `реализация Список` (методы; синтаксис БЕЗ `[T]` в
      заголовке — целевой тип уже generic по декларации; методы получают
      свою Type_Scheme, иначе первый вызов зацементировал бы T шаблона
      навсегда — см. заметку в ROADMAP §Стадия 7)
- [x] Generic-интерфейсы: `реализация ИнтерфейсX для GenericТип` больше
      не отклоняется (интерфейс сам НЕ generic — отдельная фича, вне
      scope) + 2 попутных бага (implemented_interfaces не переживал
      инстанциацию; interface-приведение пропускалось для конструктора/
      метода в позиции аргумента — баг НЕ специфичный для generics) —
      см. заметку "по generic-интерфейсам" в ROADMAP §Стадия 7
- [x] Phase F: prelude cleanup (Опция/Результат как user-declared ADT) —
      breaking change (только `Опция.Есть(...)`/`Результат.Успех(...)` и
      т.п., голые конструкторы больше не резолвятся); новый механизм
      прелюдии (core/prelude.odin) + 4 независимых бага (мерж вариантов в
      scope, тройная "map растёт из пустой" аliasing-ловушка, раскрытие
      сырого generic-шаблона в unify_types, ослабленные сигнатуры
      заменить_значение/заменить_ошибку) — см. заметку в ROADMAP §Стадия 7
- [x] E2E тесты + docs: E2E набралось инкрементально за Phase A-F, без
      отдельного прохода; `docs/language.md#дженерики` (новый раздел) +
      `AGENTS.md` дополнены, `Опция`/`Результат`-примеры в обоих
      обновлены под Phase F breaking change — см. заметку в ROADMAP
      §Стадия 7

---

## Стадия 8 — FFI фаза B: dynamic

Refs: [ROADMAP §Стадия 8](ROADMAP.md#стадия-8--ffi-фаза-b-dynamic-3-4-недели)
— существенно расширено 16.07.2026, включая исправление ошибочного
prerequisite (см. ниже) и 5 непринятых архитектурных решений, требующих
грилинга перед кодом.

**Исправленный prerequisite**: НЕ "Стадия 1 (GC finalizers обязательны)"
— такого общего механизма в Стадии 1 нет и не было (проверено —
`core/gc.odin`, ~line 417-444: `pool_release`'s cleanup для `File_Value`/
`Socket_Value` — два ЖЁСТКО ЗАШИТЫХ case'а, не generic-инфраструктура).
Хорошая новость: `Указатель(T)` с `(владеет_я)` нужен ТРЕТИЙ такой же
hardcoded case по тому же образцу — новой инфраструктуры строить не
нужно. Реальный prerequisite — только Стадия 6 (✅, `Call_Info`/
`Call_Kind`).

**Не решено — 5 вопросов для самостоятельного грилинга, см. ROADMAP для
полного разбора каждого**:
1. `foreign import` (compile-time, годится только для Стадии 4) vs
   `core:dynlib` (`dlopen`/`dlsym` в рантайме — обязательно для
   ДЕЙСТВИТЕЛЬНО динамической `внешний`-декларации) + libffi
   (`ffi_call` — вызов функции с рантайм-сигнатурой) — это ДВЕ разные
   проблемы (найти функцию vs вызвать её), обе нужны одновременно
2. Статическая линковка libffi (C toolchain в build-пайплайне) vs
   системная (`foreign import "system:ffi"`) — libffi НЕ vendored
   в репозитории
3. `Число_32`/аналоги — новый `Type_Kind` (точная диагностика, много
   работы) или чисто marshalling-аннотация внутри `внешний`-сигнатуры
   (минимальные изменения, `Число` остаётся единственным числовым типом
   для остального языка) — рекомендация начать со второго
4. `ff_структура` — новое объявление с C-совместимым memory layout
   (вероятно НЕ `Aggregate_Value`, у которого нет layout-контроля) или
   переиспользование обычной `структура` — вероятно самая объёмная
   под-задача во всей стадии
5. Платформенный охват SIGSEGV-recovery — POSIX (`sigaction`) реализуемо
   переиспользуемо, Windows (SEH) принципиально другой механизм; решить,
   входит ли Windows в scope v1

**Конкретные touch-точки в текущем коде (не зависят от решений выше)**:
- [ ] Грамматика `внешний`: новый `TokenKind` + `lookup_ident`
      (core/lexer.odin, тот же свитч что "функ"/"тип") + `^Foreign_Decl`
      в `Decls` (core/parser.odin:143-151, сейчас 7 членов) +
      `parse_foreign_decl` + новая ветка в `parse_program`'s dispatch
      (core/parser.odin:600-688, вставить перед catch-all на line 676)
- [ ] `Указатель(T)` как opaque generic-тип — точный прецедент
      `Процесс(T)` (Стадия 24: `Type_Kind.Process`, `new_process_type`,
      третья ветка `Type_Generic`-цепочки в `resolve_type_node`, БЕЗ
      `Type_Scheme`) — `Указатель(T)` четвёртая ветка той же цепочки
- [ ] `Pointer_Value` как новый Value-вариант — точный прецедент
      `File_Value`/`Socket_Value`/`Process_Value`: struct{header:
      GC_Header; ...} + добавление в `Value :: union{}` (compiler.odin)
      → Odin's exhaustive-switch САМ укажет все 5 точек в gc.odin
      (get_header/mark_value/value_size/pool_release/gc_new) как ошибки
      компиляции сразу после добавления — тот же метод, которым велась
      вся работа над Стадией 24
- [ ] Типизация `внешний`: таблица "имя → тип функции" должна строиться
      ДИНАМИЧЕСКИ из самой decl'арации (в отличие от `core/stdlib.odin`'s
      РУЧНОЙ таблицы для фс/ос/сеть) — ближе по духу к обычному
      `Function_Decl`-резолву (ПРОХОД 2, type_cheker.odin)
- [ ] `Call_Foreign` opcode (compiler.odin `Opcode` enum) — операнды по
      образцу `.Call_Builtin`/`.Call`, точная форма зависит от решения
      вопроса 1 выше
- [ ] Вендоринг libffi (если решение по вопросу 2 — vendored):
      конвенция `external/` уже задана Стадией 26 +
      `external/back`/`external/odin-http`/`external/toml_parser`

**Порядок работ** (полный список 16 шагов — см. ROADMAP, здесь только
чеклист):

- [ ] Грилинг вопросов 1-5 (архитектура — до кода)
- [ ] Грамматика `внешний` (TokenKind/lexer/Decls/parser)
- [ ] `core:dynlib`-based загрузка библиотек
- [ ] libffi bindings в Odin
- [ ] Type descriptor builder
- [ ] Primitive marshalling
- [ ] `Указатель(T)`/`Pointer_Value` + владение через `pool_release`
- [ ] String marshalling (КСтрока ↔ Panos_String)
- [ ] `ff_структура` marshalling
- [ ] `Call_Foreign` opcode + VM handler
- [ ] Тесты через libc (printf/getpid/open)
- [ ] SIGSEGV recovery
- [ ] Callback'и через ffi_closure
- [ ] (опционально) Обёртка raylib на Panos-стороне (замена Стадии 4)
- [ ] (опционально) Обёртка libc `фс` (миграция host stdlib)
- [ ] Docs — новая глава `docs/src/language/ffi.md`

---

## Стадия 9 — DOD Волна 3 (опционально)

Refs: [ROADMAP §Стадия 9](ROADMAP.md#стадия-9-опционально--dod-волна-3--инкремент-по-нужде).

Prerequisite: реальные perf-issues. Не начинать без данных.

- [ ] AST индексы (SoA `Ast_Storage`)
- [ ] TC инкрементальность
- [ ] Incremental parsing (tree-sitter-style)
- [ ] Persistent LSP cache

---

## Стадия 10 — Parser/Resolver error recovery (Hole nodes) ✅

Не было в исходном ROADMAP — сделано вне очереди по запросу пользователя
(продолжение Стадии 2: тот же accumulate-not-panic паттерн, но для
parser.odin/resolver.odin, которые до этого оставались единственными
"paniciping" стадиями пайплайна — известное ограничение MVP LSP, явно
отмеченное как TODO в Стадии 3).

Идея (error/hole node) — из практики resilient-парсеров (см. также Hazel/
typed holes): placeholder-вариант в AST union'е, несущий только `span`,
который все нижестоящие проходы трактуют как "уже отрапортовано, не
каскадировать" — то же самое, что `TY_POISON` в typechecker'е, но на
уровень выше.

- [x] `Error_Decl`/`Error_Stmt`/`Error_Pattern`/`Error_Expr`/`Error_Type_Node`
      — по одному hole-варианту в каждый из 5 AST union'ов (`Decls`, `Stmt`,
      `Pattern`, `Expr`, `Type_Node`), span-only. Компилятор сам нашёл все
      exhaustive switch'и, которым нужен новый case (P1)
- [x] `Parser.diagnostics` + `report_parse()` (дедуп по span+message, как
      `report()` в type_cheker.odin). `expect()`/`error()` перестали
      паниковать. `skip_to_sync()` — синхронизация до следующего top-level
      keyword/`конец` (P2)
- [x] Миграция всех 22 прямых `fmt.panicf` в parser.odin на report+Hole.
      Аудит форвард-прогресса на каждом сайте (consumed-before-check vs
      peek-only) — только 3 места были peek-only и требовали явного skip
      (иначе zero-progress infinite loop): `parse_program`'s two dispatch
      branches и `parse_impl_decl`'s method-loop (P3)
- [x] `Resolver_Ctx.diagnostics` + `report_resolve()`. Миграция всех 15
      panicf в resolver.odin — duplicate declaration репортится и
      продолжает (первое объявление остаётся каноническим), undefined
      variable даёт `INVALID_SYMBOL` в `node_symbols` (typechecker уже
      трактует его как poison, см. `infer_ident_expr`) (P4)
- [x] Проводка diagnostics: `Module_Graph.parse_diagnostics` (Parser живёт
      только внутри `load_module_recursive`, иначе diagnostics терялись бы
      вместе с ним), `main.odin` печатает все три источника (parse/resolve/
      typecheck) в pipeline-порядке до компиляции, LSP `publish_diagnostics`
      аналогично объединяет все три, `e2e_test.odin`'s `panic_on_diagnostics`
      обобщена на `[dynamic]Diagnostic` и вызывается на каждой стадии — все
      38 тестов прошли без переписывания (P5)
- [x] lexer.odin (4 panicf) — сделано в Стадии 12 (закрывает то, что здесь
      было отложено). module_loader.odin (5 panicf) — сделано в Стадии 20
      (изначальное обоснование "ошибки окружения, не live-typing сценарий"
      оказалось неверным для LSP: краш процесса на одном битом импорте)

Verification: `odin test ./core` 38/38, `test.ps` без регрессий, оба
бинарника билдятся чисто. Ручная проверка: синтаксическая ошибка в CLI даёт
`path:line:col: message` вместо raw panic trace; в LSP — процесс переживает
`didOpen`/`didChange` с синтаксической ошибкой, отвечает на последующие
запросы, корректно очищает diagnostics после исправления. Undefined variable
— один diagnostic, не каскад. Несколько независимых top-level ошибок в одном
файле — все репортятся, не только первая (skip_to_sync работает).

---

## Стадия 11 — Объектный API для фс/ввод_вывод (файловые дескрипторы) ✅

Не было в исходном ROADMAP — сделано вне очереди по запросу пользователя:
перевести `фс`/`ввод_вывод` с одноразовых функций (`фс.прочитать(путь)` целиком
за раз) на хэндлы с методами (`фс.открыть(путь)` → `Файл`, затем
`.прочитать()`/`.прочитать_строку()`/`.записать()`/`.закрыть()`). Область:
файлы + поток ввода (`ввод_вывод.поток()`), реализовано целиком без
пошагового подтверждения.

- [x] `File_Value` — новый вариант `Value` (12-й), `header: GC_Header`,
      `handle: ^os.File`, `reader: bufio.Reader`, `path`, `is_open`,
      `is_stdin`. Компилятор сам нашёл все exhaustive-switch сайты в
      gc.odin (get_header/mark_value/value_size/pool_release), которым
      нужен новый case (П1)
- [x] GC-интеграция: free-list `free_files` (тот же object-pooling
      паттерн, что и у остальных 9 типов), **finalizer в `pool_release`** —
      если файл стал недостижим, но `.закрыть()` не вызван явно, GC сам
      закрывает ОС-хендл через `close_file_value` (общая точка с explicit
      close, гейт идемпотентности — `is_open`). Стдин-обёртка не владеет
      ОС-хендлом, финализатор для неё no-op (П2)
- [x] `фс.открыть(путь) -> Результат(Файл, Ошибка)` — `{.Read, .Write,
      .Create}`, не truncate. Методы через существующий
      `invoke_collection_method`/`Invoke_Collection` (тот же механизм, что
      у Option/Result/Array/Map — новых VM-опкодов не потребовалось):
      `.прочитать()`, `.прочитать_строку()`, `.записать(текст)`,
      `.закрыть()`. `ввод_вывод.поток() -> Файл` — та же File_Value с
      `is_stdin=true`. Единый `vm.stdin_reader` (bufio.Reader поверх
      `os.stdin`, ленивая инициализация) — сколько бы раз ни вызвали
      `поток()`, реальный ОС-поток читается ровно одним буферизованным
      reader'ом, независимые readers над одним stdin теряли бы байты (П3)
- [x] Тайпчекер: `Type_Kind.File`, `TY_FILE` (интернированный, как
      `TY_ERROR`), зарегистрирован в `BASE_TYPES` как `"Файл"` (можно
      писать аннотацией). `FILE_METHODS` — по образцу
      `OPTION_METHODS`/`RESULT_METHODS`, заведена в `standard_method_type`
      (П4)
- [x] e2e-тесты: запись через дескриптор → чтение one-shot'ом (roundtrip),
      `.прочитать_строку()` → `.прочитать()` делят курсор (общий
      bufio.Reader, вторая строка не читает файл заново с начала), ошибка
      открытия (несуществующая директория), структурный smoke-тест
      `ввод_вывод.поток()` (реального чтения из stdin не делали — процесс
      теста не подключён к пайпу, блокирующее чтение повесило бы suite)
      (П6)

**Отклонение от исходного плана**: П5 (переписать старые одноразовые
`фс.прочитать`/`фс.записать` через новые open/read/write/close изнутри,
для консистентности) сознательно пропущен — рабочий код без причины для
изменения, три похожие реализации лучше преждевременной абстракции с
риском регрессии в уже покрытом тестами пути.

Verification: `odin test ./core` 44/44 (было 40 — добавлено 4 на этот
объектный API), оба бинарника билдятся чисто, ручной прогон CLI
(запись+чтение через дескриптор, см. transcript) подтверждает корректность.

---

## Стадия 12 — Lexer error-recovery (Стадия 10 П6) + попутные находки ✅

Не было в исходном ROADMAP — начато по запросу пользователя как разбор
жалобы "невозможно обращаться ко вложенным модулям" (`test_toml.ps`).
Резолв вложенных путей (`импорт "кодирование/toml"`) уже работал —
регрессия закрыта e2e-тестом; реальная причина краша была в другом.

- [x] **lexer.odin error-recovery (Стадия 10 П6)**: 4 panicf →
      accumulate-not-panic. `Lexer.diagnostics` + `report_lex()` (тот же
      дедуп-паттерн, что и report_parse/report_resolve). Три стратегии
      восстановления: неизвестный escape → литеральный символ вместо '\';
      незакрытая строка (EOF внутри или после escape) → best-effort
      содержимое, следующий вызов естественно вернёт .EOF; неожиданный
      символ верхнего уровня → символ молча выкидывается из потока токенов
      (`report_lex` + `advance` + `continue`, без Hole-токена — парсер о
      нём не узнаёт вообще). `tokenize()` теперь возвращает
      `([dynamic]Token, [dynamic]Diagnostic)`, оба return-value прокинуты
      во все 4 вызывающих места (module_loader.odin → parse_diagnostics,
      3×e2e_test.odin)
- [x] **Критичный баг in the wild, найден по цепочке**: `TokenStream.
      next_token`/`peek_token` возвращали `nil` при уходе за границу
      массива токенов. Пока лексер паниковал на первой ошибке, этот путь
      был недостижим на практике; как только лексер научился
      восстанавливаться, парсер стал доходить до входа "оборвано прямо
      перед физическим EOF" (напр. незакрытая строка/блок в конце файла) —
      и `parse_program`'s `for peek_token(...).kind != .EOF` (и другие
      подобные циклы) сегфолтили на разыменовании nil. Исправлено:
      `next_token`/`peek_token` больше никогда не возвращают nil — клэмпят
      `current_idx` на терминальном `.EOF`-токене (`tokenize()`
      гарантирует, что он всегда последний), EOF — устойчивое состояние,
      а не обрыв
- [x] **Второй критичный баг, найден при написании regression-теста для
      строки.срез**: `не X` (логическое отрицание) компилировался в
      no-op — `compile_expr`'s `#partial switch e.op` для `^Unary_Expr`
      обрабатывал только `.Minus`, `.Negate` не имел case и просто
      падал сквозь свитч без эмита опкода. Баг тихий (не падение, а
      неверный результат) и существовал независимо от всей остальной
      работы этой сессии — пойман тестом на `строки.цифра_или_буква`,
      не проявлял себя ни в одном из 44 существовавших e2e-тестов
- [x] Новый builtin-модуль `строки`: `срез(текст, начало, конец)` (замена
      отсутствующего в языке `[a:b]`-синтаксиса — `string_slice_by_rune` в
      utils.odin, срез по рунам, согласовано с get_character_at/длина),
      `это_цифра`/`это_буква`/`цифра_или_буква` (однобуквенная Строка →
      Булево, через `core:unicode`)
- [x] `std/кодирование/toml.ps` починен: убраны реальные баги (не только
      синтаксис) — `"""` вместо `"\""`, одинарные кавычки для строк (язык
      их не поддерживает), `функц`→`функ`, `тогдаа`→`тогда`, отсутствующие
      `тогда`/`пер`, method-receiver без аннотации типа, необъявленный
      импорт `строки`, срезы `[a:b]` заменены на `строки.срез(...)`.
      Добавлен `Токен.вСтроку()` — `test_toml.ps` его вызывал, но метод
      никогда не существовал
- [x] Regression-тест на вложенный импорт (`module_fixture_nested_main.ps`
      → `module_fixture_nested/helper.ps`) — подтверждает, что исходная
      жалоба была про сломанный файл, не про резолв

Verification: `odin test ./core` 48/48 (было 44 — 3 на lexer recovery,
1 на строки), оба бинарника билдятся чисто, `test_toml.ps`/`test.ps`
выполняются без регрессий (ручной прогон).

---

## Стадия 13 — Реальный TOML-парсер + `реализация <перечисление>` (третий критичный баг) ✅

Не было в исходном ROADMAP — запрос "допиши toml парсер" (`std/кодирование/
toml.ps` до этого содержал только токенизатор, без дерева значений и
самого парсера).

- [x] `Значение` — рекурсивный ADT (`Строка`/`Число`/`Булево`/`Список(
      Массив(Значение))`/`Таблица(Соответствие(Строка, Значение))`) —
      подтверждено, что резолвер уже умеет в самоссылающиеся типы варианта
      (поле enum'а ссылается на сам этот enum) без специальной поддержки
      — просто проверено минимальным репро перед тем, как строить на этом
      всю схему
- [x] `Парсер` (обёртка над `Токенизатор` с mutable lookahead-токеном) +
      рекурсивный `разобрать_значение` (строки/числа/булевы/массивы,
      массивы рекурсивно поддерживают вложенность), `разобрать(текст) ->
      Результат(Значение, Ошибка)` — секции `[x]`, `ключ = значение`,
      накопление в `Соответствие` по секциям
- [x] Токенизатор: типы токенов `ЗНАЧЕНИЕ` (объединяла строки/числа,
      неразличимо на этапе парсинга — `"42"` и `42` тегались одинаково)
      разведены на `СТРОКА`/`ЧИСЛО`/`БУЛЕВО`; добавлен токен `ЗАПЯТАЯ`
      для массивов
- [x] Новый builtin `строки::в_число(текст) -> Результат(Число, Ошибка)`
      (`core:strconv.parse_f64`) — конвертация текста числового токена в
      реальное Число, единственный способ это сделать не существовал
      вообще
- [x] **Третий критичный баг сессии**: `реализация <Перечисление>` (impl-
      блок методов на пользовательском enum, не на структуре) падала
      сегфолтом. ПРОХОД 3 typecheck'а регистрировал методы только для
      `.Struct`-таргетов, для остальных — репортил diagnostic и
      `continue`, не заполняя `symbol_types[метод]`; ПРОХОД 4 не проверял
      этот случай и разыменовывал `nil.params` в `bind_function_args`.
      Решено ПРАВИЛЬНО, не заглушкой: `реализация` для перечисления теперь
      полноценно поддержана (методы регистрируются и диспетчеризуются тем
      же путём, что у структур — `.Method_Struct` в compiler.odin трактует
      получателя как "просто первый аргумент вызова", ему всё равно,
      Aggregate_Value это или Variant_Value). Реализация интерфейсов для
      перечислений осталась НЕ поддержана (contract-путь писан и тестирован
      только под Struct) — это репортится диагностикой, не падает
- [x] e2e-тесты на оба среза бага: успешный `реализация Enum` + вызов
      метода, и явный reject `реализация Интерфейс для Enum`

Verification: `odin test ./core` 50/50 (было 48), оба бинарника билдятся
чисто, `test_toml.ps` реально парсит TOML-текст (секции, строки, числа,
булевы, массив) и читает значения обратно — не просто конструирует один
`Токен` вручную, как раньше.

---

## Стадия 14 — Модуль `сеть`: TCP-клиент ✅

Не было в исходном ROADMAP — запрос "работа с сетью" после уточнения
объёма (только TCP-клиент, без сервера и без HTTP-обёртки — в `core:net`
готового HTTP нет вообще, только сырые сокеты).

- [x] `Socket_Value` — новый вариант `Value` (13-й), тот же объектный
      паттерн, что у `File_Value` (Стадия 11): `header`, `socket:
      net.TCP_Socket`, `reader: bufio.Reader`, `is_open`. Компилятор сам
      нашёл все exhaustive-switch сайты в gc.odin
- [x] GC-интеграция: `free_sockets` пул + finalizer в `pool_release`,
      закрывающий недостижимое-но-незакрытое соединение через
      `close_socket_value` (общая точка с explicit `.закрыть()`, тот же
      idempotency-гейт `is_open`, что у файлов)
- [x] `tcp_to_stream`/`tcp_recv_stream_proc` — самодельный `io.Stream`
      поверх `net.recv_tcp` (core:net не даёт готового адаптера, в отличие
      от `os.to_stream` для файлов). Реализован только `.Read` — `io.read`
      зовёт ровно этот mode, `.Query` не требуется. `recv_tcp` возвращает
      `0, nil` на graceful close — в стриме это явно транслируется в
      `io.Error.EOF`, чтобы bufio не тратил до 100 попыток на
      `No_Progress`, прежде чем сдаться. Благодаря этому адаптеру
      `read_line_from_reader`/`read_all_from_reader` (Стадия 11) переиспользованы
      для сокетов один в один — нового пути чтения не потребовалось
- [x] `сеть.подключиться(хост, порт) -> Результат(Соединение, Ошибка)`
      (`net.dial_tcp_from_hostname_with_port_override`), методы через
      существующий `Invoke_Collection`: `.получить()`, `.получить_строку()`,
      `.отправить(текст)` (`net.send_tcp`), `.закрыть()`
- [x] Тайпчекер: `Type_Kind.Connection`, `TY_CONNECTION` (в BASE_TYPES как
      `"Соединение"`), `CONNECTION_METHODS` — по образцу FILE_METHODS,
      заведена в `standard_method_type`
- [x] e2e: connection refused на 127.0.0.1 (ошибка ядра, не таймаут — не
      вешает suite). Ручная проверка полного цикла send/recv — Python
      TCP-эхо-сервер на loopback, `сеть.подключиться` +
      `.отправить`/`.получить`/`.закрыть` через реальный сокет, ответ
      получен корректно

Verification: `odin test ./core` 51/51 (было 50), оба бинарника билдятся
чисто, ручной прогон против настоящего TCP-сервера (Python, `127.0.0.1`)
подтверждает send/recv end-to-end.

---

## Стадия 15 — `std/сеть/http.ps`: простой HTTP/1.1-клиент на Panos ✅

Не было в исходном ROADMAP — запрос "напиши простенький http на panos и
добавь в стандартную библиотеку". В отличие от Стадий 11/14 (объектный
API/сеть — расширения host-рантайма на Odin), это чисто Panos-код поверх
уже существующего `сеть.подключиться` — HTTP как библиотека языка, не как
встроенный модуль.

- [x] Новый builtin `строки::из_числа(число) -> Строка` (`fmt.tprintf("%v",
      ...)` — уже даёт "5", не "5.000000", для целых) — нужен для
      Content-Length в POST-запросах; `в_число`/`из_числа` теперь
      симметричная пара
- [x] `std/сеть/http.ps`: `Адрес` (хост/порт/путь) и `Ответ`
      (статус/тело) — структуры, не ADT (нет вариантов, простые контейнеры
      полей). `разобрать_адрес(текст) -> Результат(Адрес, Ошибка)` —
      только `http://` (без TLS — `core:net` не даёт TLS, https вне
      объёма), самописный линейный `найти(текст, образец, от)` для
      поиска `/` и `:` (в языке нет indexOf). `получить(ссылка)` /
      `отправить_пост(ссылка, тело)` — общий `выполнить(метод, ...)`:
      строит запрос руками (`Connection: close`, поэтому чтение тела —
      просто "до EOF", без Content-Length/chunked на стороне клиента),
      шлёт через `сеть.подключиться`, парсит статус-строку и тело по
      `\r\n\r\n`
- [x] e2e: `разобрать_адрес` (host/port/path, дефолтный порт 80,
      `https://` явно отклонён) — чистая логика, без сокета, не зависит от
      сети/CI-окружения. Полный GET/POST через реальный HTTP-сервер
      (Python `http.server` на loopback) проверен вручную: статус 200,
      тело; статус 404 на несуществующем пути

Verification: `odin test ./core` 52/52 (было 51), оба бинарника билдятся
чисто, `test_http.ps` против Python `http.server` на `127.0.0.1:8972`
возвращает корректные статус и тело.

---

## Стадия 16 — HTTP: заголовки, query, статус-хелперы ✅

Продолжение Стадии 15 по запросу пользователя ("что насчёт остальных
частей — заголовки, query, коды возврата"). Перед реализацией — уточнение
объёма (headers/query/статус-хелперы да, chunked encoding нет) и **отдельное
согласование** двух design-решений, которые сначала сделал без спроса и
за это получил справедливое замечание:

- [x] `Соответствие.записи() -> Массив((К, З))` — единственный способ
      обойти произвольную Map (в языке нет for-in, добавлять его
      отдельным вопросом решили НЕ делать — Массив пар + существующий
      `пока`-цикл дешевле и не трогает parser/resolver/compiler). Сначала
      сделано без согласования — переспрошено, подтверждено, оставлено
      как было
- [x] `сеть.кодировать_url(текст) -> Строка` — percent-encoding (RFC 3986
      unreserved как есть, всё остальное `%XX` по БАЙТАМ строки, не рунам —
      корректно для многобайтовой UTF-8). Изначально положил в `строки`,
      пользователь указал, что это сетевая/HTTP-специфика — перенесено в
      `сеть`
- [x] `Ответ.заголовки: Соответствие(Строка, Строка)` — разбор
      "Заголовок: значение\r\n..." построчно через `найти`. `.заголовок(имя)
      -> Опция(Строка)` — регистро-чувствительно (как прислал сервер, без
      нормализации регистра HTTP-заголовков — сознательное упрощение)
- [x] Заголовки запроса: `построить_запрос` принимает
      `доп_заголовки: Соответствие(Строка, Строка)`, сериализует через
      `.записи()`. `получить_с_заголовками`/`отправить_пост_с_заголовками`
      — новые экспорты, `получить`/`отправить_пост` не сломаны (передают
      пустую Map)
- [x] `построить_query(параметры) -> Строка` — "?a=b&c=d" с
      `сеть.кодировать_url` на ключах и значениях. Комбинаторная функция
      получить_с_query НЕ добавлена — вызывающий сам клеит
      `хттп.получить(url + хттп.построить_query(...))`, чтобы не
      разводить N² функций на пересечении method×headers×query
- [x] Статус-хелперы на `Ответ`: `.успех()` (200-299), `.редирект()`
      (300-399), `.ошибка_клиента()` (400-499), `.ошибка_сервера()`
      (500-599) — через `>`/`<`/`==` (в языке нет `>=`/`<=`)
- [x] e2e: `http_url_fixture_main.ps` расширен (адреса + query + статус-
      хелперы, без сокета). Ручная проверка: GET с чтением заголовков
      ответа (Content-Type) + query-строка с кириллицей (percent-encoded
      корректно); POST с кастомными заголовками (Content-Type, X-Test)
      против сырого TCP-сервера на Python, который печатает ПОЛУЧЕННЫЙ
      запрос целиком — подтверждено, что Content-Length/заголовки/тело
      уходят на провод именно так, как ожидалось, не только "клиент не
      упал"

**Отклонение от исходного плана**: chunked transfer-encoding сознательно
не реализован (пользователь подтвердил, что не нужен сейчас) — тело всё
ещё читается "до EOF", ломается на серверах, которые шлют chunked вопреки
`Connection: close`.

Verification: `odin test ./core` 52/52 (без изменения числа — новые
проверки внутри уже существующего http_url_fixture_main.ps), оба
бинарника билдятся чисто. Ручной прогон: GET с заголовками+query против
Python `http.server`, POST с заголовками против сырого TCP-сервера
(проверка byte-for-byte того, что ушло на провод).

---

## Стадия 17 — for-in + попутный scope-баг if/while ✅

Не было в исходном ROADMAP — запрос "добавь for-in, это же просто
синтаксический сахар". По факту почти так и вышло, с двумя оговорками,
обе — по согласованию с пользователем (не решались в одиночку):

- [x] **"в" — не глобальное зарезервированное слово**. Первая попытка
      (глобальный `.In`-токен в лексере) тут же сломала test.ps —
      `Прямоугольник(ш, в)` уже использует "в" как binder-имя (высота).
      Откачено: "в" сравнивается по тексту токена только в ОДНОЙ позиции
      грамматики (сразу после списка переменных `для`), контекстный
      keyword, не резервирует слово нигде больше
- [x] **Desugar целиком в parser.odin, без нового AST-узла**. Первая
      попытка добавляла `Block_Stmt` (список statement'ов как один Stmt) с
      passthrough-кейсами в resolver/type_cheker/compiler — по замечанию
      пользователя переделано: `parse_stmt_into(p, &body)` пишет 1+
      statement прямо в целевой список, все 6 мест сборки тела
      (функция/если/иначе/пока/лямбда/ветка выбора) зовут его вместо
      `append(&body, parse_stmt(p))`. Резолвер/type_cheker/compiler/vm не
      знают, что для-in существует — видят обычные Let/While/If/Index
- [x] `для <ident> в <expr> цикл...конец` и `для (a, b, ...) в <expr>
      цикл...конец` (деструктуризация тупла — под `Соответствие.записи()`
      из Стадии 16). Раскрывается в `пер __for_N_iter = expr; пер
      __for_N_idx = -1; пока истина цикл __for_N_idx = __for_N_idx + 1;
      если __for_N_idx == __for_N_iter.длина() тогда прервать конец; пер
      <элемент> = __for_N_iter[__for_N_idx]; <тело> конец`. Инкремент —
      ПЕРЕД телом (не после) — иначе `продолжить` (прыгает на re-check
      условия, см. Loop_Context.continue_target) перепрыгивал бы через
      инкремент, бесконечный цикл. Работает только с array-like
      (`.длина()` + `[idx]`) — Map не индексируется позиционно, отсюда
      требование сначала `.записи()`
- [x] **Второй попутный баг, найден на practice**: `для х в а цикл...конец`
      сразу за `для х в б цикл...конец` (то же имя, СОСЕДНИЕ, не
      вложенные, циклы) падало "Имя х уже объявлено" — оказалось, `если`/
      `пока` вообще не изолировали scope в резолвере (`пер` внутри
      протекал в объемлющую функцию). Не баг for-in — баг всего языка,
      for-in просто сделал его заметным (короткие имена типа `х`
      переиспользуются в каждом цикле). Пользователь выбрал чинить в
      корне, не документировать как ограничение: `push_scope`/`pop_scope`
      вокруг `If_Expr.then_branch`/`else_branch` и `While_Expr.body` в
      resolve_expr — тот же паттерн, что уже был у `Match_Expr`/
      `Lambda_Expr`. `ctx.locals`/slot-allocation в compiler.odin это не
      затрагивает (там нет scope_depth-based reuse вообще — slot'ы растут
      монотонно по количеству `Let_Stmt`-узлов в AST, не зависят от
      резолверной scope)
- [x] e2e: сумма по массиву, деструктуризация `.записи()`, continue+break
      вместе (проверяет именно тот сценарий, из-за которого инкремент
      стоит перед телом), пустой массив (0 итераций), ранний `возврат`
      изнутри цикла, два `для` с одинаковым именем переменной (не
      вложенные), вложенные `для`. Отдельно — regression-тест на сам
      scope-фикс (не про for-in): одноимённый `пер` в двух НЕ вложенных
      `если`, мутация внешней переменной видна после блока

Verification: `odin test ./core` 60/60 (было 52 — 6 на for-in, 2 на
scope-фикс), оба бинарника билдятся чисто. `test.ps`/`test_toml.ps`/
`http_url_fixture_main.ps` — без регрессий (ручной прогон, важно
проверить именно из-за resolver-level scope-изменения, которое касается
не только for-in, а вообще всех if/while в языке).

---

## Стадия 18 — Варианты перечислений больше не в глобальном namespace ✅

По запросу пользователя: `тип X = перечисление` и `тип Y = перечисление` с
одноимённым вариантом (напр. оба `Точка`) конфликтовали как "имя варианта
конфликтует с уже объявленным символом в модуле" — варианты жили в ТОЙ ЖЕ
плоской `module.scope.symbols`, что функции/типы/переменные. Обсуждён и
выбран вариант "только квалифицированный доступ" (`Тип.Вариант`, не
context-inferred bare — тот проще и без риска, но означает breaking change
для всего существующего кода на bare-конструкторах).

- [x] `Module.variants: map[Symbol_Id]map[Interned]Symbol_Id` (владелец-тип
      → имя варианта → символ) — отдельно от `scope.symbols`. Регистрация
      варианта (`register_top_level_decl`, `Enum_Decl`) пишет туда, не в
      scope — коллизий между РАЗНЫМИ типами больше не бывает по
      конструкции map'ы (два уровня ключей)
- [x] Квалифицированный доступ `Тип.Вариант` (уже существовал для
      кросс-модульного `модуль.Тип.Вариант`) починен под новую map —
      `owner_module.variants[obj_sym][...]` вместо
      `owner_module.scope.symbols[...]`
- [x] **Bare-конструктор (`Круг(5)` без префикса типа) больше не
      резолвится вообще** — `Ident_Expr` для голого имени варианта не
      находит символ в scope, "undefined variable". Единственный способ
      построить вариант — `Тип.Вариант(...)`
- [x] Паттерны в `выбор` (`Точка -> ...`, `Круг(р) -> ...`) НЕ затронуты —
      `classify_pattern` в type_cheker.odin резолвит имя варианта по
      `expected_type.variant_index` (тип уже известен из subject'а `выбор`),
      никогда не ходил через resolver scope. Это подтверждено ДО правки
      (прочитан код), не обнаружено постфактум
- [x] Кросс-модульный ОДНОуровневый шорткат (`ф.Круг(...)`, без имени типа,
      через `module.exports`) сознательно НЕ тронут — жалоба пользователя
      была про засорение namespace'а ВНУТРИ модуля, этот путь и так требует
      квалификации модулем
- [x] Обновлены все существующие `.ps`-файлы с bare-конструкторами:
      `test.ps`, `std/кодирование/toml.ps` (10 сайтов — `Значение.Число`/
      `.Строка`/`.Булево`/`.Список`/`.Таблица`), 17 e2e-тестов в
      `core/e2e_test.odin`. Паттерны (`Точка ->`) везде оставлены bare —
      их трогать не нужно
- [x] Новые e2e-тесты: два перечисления с одинаковым именем варианта
      сосуществуют (позитивный), bare-конструктор репортит "undefined
      variable" (негативный, регрессия на будущее)

Verification: `odin test ./core` 62/62 (было 60 — 2 новых), оба бинарника
билдятся чисто. `test.ps`/`test_toml.ps`/`test_http.ps` (живой HTTP-сервер)/
`adt_fixture_*.ps` (в т.ч. кросс-модульные `ф.Круг`/`ф.Фигура.Круг`, и
намеренно-падающий `adt_fixture_private_use.ps`) — без регрессий, ручной
прогон каждого.

---

## Стадия 19 — Пусто-функция не обязана заканчиваться Пусто-выражением ✅

По запросу пользователя, найдено на внешнем проекте (`../panosiki/pan/
start.ps`): `функ старт() -> Пусто ... побочный_эффект_или_вызов() конец`
падало "функция объявлена как 'Пусто', но последнее выражение имеет тип
X" — раздражающе, если последняя строчка функции просто вызывает что-то
ради побочного эффекта, а не ради значения.

- [x] Найдено: `check_function_body` (type_cheker.odin) требовал
      `body_type == TY_VOID` (или unify с ним) для Пусто-функций, репортя
      ошибку иначе. Убрано — Пусто-функция больше не проверяет тип
      последнего выражения вообще, значение молча отбрасывается
- [x] Проверено, что это БЕЗОПАСНО на уровне VM ДО правки type_cheker'а:
      `compile_block(ctx, body, is_expr=true)` уже безусловно оставляет
      значение последнего Expr_Stmt на стеке (не зависит от
      `returns_value`), но `.Return` в vm.odin снимает "лишнее" значение
      со стека и кладёт его вызывающему ТОЛЬКО если
      `frame.function.returns_value` — для Пусто он молча теряется.
      Стек не рассинхронизируется ни при однократном, ни при повторных
      вызовах — только тайпчекер был лишним источником трения
- [x] Явный `возврат X` внутри Пусто-функции — ДРУГОЙ код-путь
      (`check_stmt`'s `Return_Stmt`, не `infer_block_type`) и
      сознательно НЕ тронут: по-прежнему ошибка. Явно написанный
      `возврат 5` при заявленном `Пусто` — осознанная ошибка автора, не
      "последнее выражение как значение по умолчанию"
- [x] e2e: Пусто-функция с трейлинг-вызовом ненулевого типа, вызванная
      несколько раз подряд (регрессия на стек), плюс явный `возврат X` в
      Пусто по-прежнему падает

Verification: `odin test ./core` 64/64 (было 62 — 2 новых), оба бинарника
билдятся чисто. `../panosiki/pan/start.ps` (внешний проект пользователя,
источник находки) — исправленный по Стадии 18 (`Флаг.флСтрока`) файл
выполняется чисто.

---

## Стадия 20 — module_loader.odin error-recovery: LSP больше не крашится ✅

Найдено на реальном внешнем проекте пользователя (`../panosiki/pan/
start.ps`): открытие файла в Neovim роняло **весь LSP-процесс** (не
диагностику одного документа). Причина: `module_loader.odin` — последний
оставшийся `fmt.panicf`-путь пайплайна, сознательно отложенный в Стадии
10 П6 с обоснованием "file-not-found/circular import — ошибки окружения,
не live-typing сценарий". Обоснование оказалось неверным для LSP: файл вне
панos-репы без видимого `PANOS_STDLIB`/`std` рядом — обычный live-typing
сценарий, `fmt.panicf` в нём убивает процесс целиком.

- [x] `read_file_text` возвращает `(data, err_msg, ok)` вместо panicf —
      3 сайта ошибок (файл не существует / не открылся / не прочитался)
- [x] `load_module_recursive` получил `importer_span: Span = {}` — span
      импортирующего `Import_Decl` для diagnostic'а (zero-value для
      входного файла — там винить нечего, см. main.odin's отдельную
      проверку `entry_module == nil`, которая уже существовала и уже
      умела с этим жить, просто раньше до неё не доходило). Все 5 panicf
      → `append(&graph.parse_diagnostics, ...)` + `return nil`/`continue`,
      граф просто не получает эту вершину
- [x] Резолвер УЖЕ был готов к отсутствующей вершине графа
      (`register_top_level_decl::Import_Decl` проверяет `ok` из
      map-lookup'а) — задел с прошлых стадий, изменений не потребовал
- [x] Попутно (не код-баг, но source of confusion): у
      `vim.lsp.start()` в `editors/nvim/lua/panos/init.lua` нет
      `cmd_env` — LSP-процесс наследует окружение Neovim, не шелла
      пользователя. Если `PANOS_STDLIB` экспортирован в `.zshrc`, но
      Neovim запущен не из того шелла (GUI/другой терминал/login shell
      до экспорта) — переменная процессу не видна, `std`-резолв молча не
      срабатывает. Диагностировано (`:!echo $PANOS_STDLIB` внутри
      Neovim), README.md **не обновлён** — нужно ли документировать
      `cmd_env` в setup() или это already-understood Neovim gotcha,
      пользователь не запросил
- [x] e2e: `load_module_graph` на файле с несуществующим импортом — не
      падает, `graph.parse_diagnostics` содержит ожидаемое сообщение

Verification: `odin test ./core` 65/65 (было 64 — 1 новый), оба бинарника
билдятся чисто. Воспроизведено И проверено вживую через сырой JSON-RPC
(Python-клиент, didOpen на `../panosiki/pan/start.ps` с cwd вне
панos-репы) — ДО фикса: `EXIT CODE -5` (SIGTRAP), процесс дохнет. ПОСЛЕ:
процесс жив, корректный `publishDiagnostics` с "Module Loader Error:
модуль '...' не найден" + производный Resolve Error, без каскада.

---

## Стадия 21 — Диагностика: для-in напрямую на Соответствие ✅

Найдено на том же внешнем проекте (`../panosiki/pan/start.ps`): `для x в
моя_карта цикл` (без `.записи()`) давало неинформативную ошибку
`"ожидался 'Строка', получен 'Число'"` без намёка на причину.
Подтверждено пользователем как ожидаемое поведение (не баг for-in) — но
сообщение об ошибке улучшено, раз уж это самый очевидный способ
неправильно использовать новую фичу.

- [x] `infer_index_expr` (Map-ветка): при несовпадении, если индекс —
      Число, а ключ карты — нет (сигнатура именно этой ошибки), отдельное
      сообщение — "Соответствие не поддерживает позиционный доступ; для
      перебора элементов используйте .записи() и 'для (ключ, значение)
      в ...'". Остальные несовпадения типа ключа (не через for-in) —
      без изменений, тот же generic-путь, что раньше
- [x] e2e: новое сообщение на for-in-паттерне, regression-тест что
      обычная неверно-типизированная индексация карты не задета

Verification: `odin test ./core` 67/67 (было 65 — 2 новых), оба
бинарника + `panos-lsp` в `~/.local/bin` (через `just build-lsp`)
пересобраны. `../panosiki/pan/start.ps` теперь даёт понятное сообщение
на строке 64.

---

## Стадия 22 — Сравниваемое (Ord) и Равнозначное (Eq): operator sugar ✅

Refs: [ROADMAP §Стадия 22](ROADMAP.md#стадия-22--сравниваемое-ord-и-равнозначное-eq-operator-sugar).

Цель: дать пользовательским структурам `<`/`>`/`<=`/`>=` через
`реализация Сравниваемое для Тип` и опционально переопределяемое
`==`/`!=` через `реализация Равнозначное для Тип`. Sugar резолвится в
typecheck/compile, не новый рантайм-механизм. Вне scope v1: generic-
функции (тело типизируется один раз абстрактно — `T < T` без
trait-bound синтаксиса, которого нет, резолвить нельзя).

- [x] Self-тип в интерфейсах: фикс `interface_method_types_match`/
      проверки контракта (type_cheker.odin ~1608-1625) — параметр,
      объявленный типом самого интерфейса, матчится на конкретный
      target_type импла, не структурно на интерфейсный тип
- [x] Prelude: `тип Сравниваемое = интерфейс`/`тип Равнозначное =
      интерфейс` в `PRELUDE_SOURCE` (core/prelude.odin) —
      `сравнить(другое) -> Число` (-1/0/1), `равно(другое) -> Булево`
- [x] `prelude_comparable_sym`/`prelude_equatable_sym` на
      `Module_Graph` (resolver.odin) + `Resolver_Ctx`, заполнение в
      `merge_prelude_exports` (по образцу `prelude_option_sym`)
- [x] Typechecker: резолв sugar в `.Less`/`.Greater`/`.LessEqual`/
      `.GreaterEqual` (type_cheker.odin ~2577) — лукап
      `implemented_interfaces` + `method_lookup(ctx, left_t,
      "сравнить")`, запись `ctx.call_infos[expr] =
      Call_Info{kind=.Method_Struct, symbol_ref=...}`; нет impl —
      diagnostic, не молчаливый фоллбэк
- [x] Grilled: точное сообщение для несовместимых операндов —
      `left_t` реализует Сравниваемое, но `right_t != left_t` (напр.
      `Точка < Линия`, `Точка < 5`) — "тип 'Точка' реализует
      Сравниваемое, но не с типом 'Линия'/'Число'", НЕ старое "ожидает
      два числа"
- [x] Typechecker: резолв sugar в `.Equal`/`.NotEqual` (~2589) — та же
      схема через `Равнозначное`/`равно`; нет impl — падает в текущий
      структурный `value_equals`-путь без diagnostic (opt-in override)
- [x] Compiler: новая ветка в `^Binary_Expr`-кейсе (compiler.odin
      ~501-565) — реюз `.Method_Struct`-кодогена (push fn-константа,
      компиляция e.left/e.right, `.Call 2`); для Ord — `emit_constant(0.0)`
      + переиспользование существующей пары опкодов
      (`.Less`/`.Greater`/`.Greater;.Negate`/`.Less;.Negate`); для Eq —
      прямой результат, `.Negate` для `!=`
- [x] e2e: структура с `реализация Сравниваемое` — `<`/`>`/`<=`/`>=`
      (сортировка через `отсортировать` НЕ получилась — см. находку ниже,
      прямые операторные тесты подтверждают фичу полностью)
- [x] e2e: структура БЕЗ `реализация Сравниваемое` — `<` даёт понятную
      diagnostic, не крэш
- [x] e2e: структура с `реализация Равнозначное` (нестандартное сравнение,
      напр. по одному полю) — `==` зовёт `равно`, не структурный путь
- [x] e2e: структура БЕЗ `реализация Равнозначное` — `==` работает как
      раньше (регрессия старого структурного пути)
- [x] e2e: Self-фикс отдельно — метод `сравнить`, реально читающий поля
      `другое.x`/`другое.y` (не только typecheck, а исполнение)
- [x] e2e: две РАЗНЫЕ Сравниваемые структуры (`Точка < Линия`) и
      Сравниваемое-структура с `Число` (`Точка < 5`) — точное сообщение
      про несовместимость, не старое "ожидает два числа"

**Найдено попутно И ИСПРАВЛЕНО (НЕ баг Стадии 22, предсуществующий)**:
`кол.отсортировать`/`кол.отфильтровать` (std/коллекции.ps) ломали
generic-инференс, когда T — структура (`результат[0].x` → "попытка
получить поле у не-структуры"). Воспроизведено И БЕЗ Ord/Eq (`a.x <
b.x`, только числа) — не связано со Стадией 22. Root cause: вызов
экспортированной generic-функции через алиас модуля не инстанцировал T
заново (`Type_Ctx.symbol_schemes` не шарился между модулями, в отличие
от `symbol_types`). Фикс — `Module_Graph.symbol_schemes` (накапливается
в `resolve_and_typecheck_all`, раздаётся через `new_type_ctx`, тот же
паттерн, что `prelude_symbol_schemes`) + `infer_call_expr` инстанцирует
через `instantiate_scheme`, если схема есть. Регрессионный тест —
`fixtures/generic_cross_module_fixture_*.ps` (`run_module_file`, баг
специфичен межмодульному вызову).

### Verification

- [x] `odin test ./core` — 89/89 (было 82; +6 для Ord/Eq, +1 для
      найденного и исправленного бага), без регрессий
- [x] `odin build .` / `odin build ./lsp` / `odin build wasm
      -target:js_wasm32` — все три цели чисто (core/-файлы затронуты,
      используются всеми тремя)

---

## Стадия 23 (кандидаты, не исследовано) — дальнейшие type classes

Refs: [ROADMAP §Стадия 23](ROADMAP.md#стадия-23-кандидаты-не-исследовано--дальнейшие-type-classes).

Список кандидатов из обсуждения — НЕ прошёл тот же уровень исследования,
что Стадия 22 (Explore-агенты, file:line-цитаты). Пункты ниже —
investigation-задачи (найти hook-точку/тир сложности), не implementation-
чеклист — писать Порядок работ с file:line можно только после
исследования каждого. **Grilled**: делается СТРОГО ПОСЛЕ Стадии 22
(не объединяется в один заход), каждый из трёх лёгких кандидатов
получает свой короткий Explore/Read-проход перед стартом.

- [x] **Печатаемое (Show)** — гипотеза плана была НЕВЕРНА: авто-
      форматирования (`%v`-дампа) для non-string печать() не было вообще
      (`expect_string_arg` паниковал), строковой интерполяции в языке
      нет. Grilled: `печать`/`строка` сделаны полиморфными (принимают
      ЛЮБОЙ Value). Механизм — НЕ operator-sugar (Aggregate_Value без
      RTTI, метод обязан резолвиться на call site) — новый
      `Call_Kind.Print_Value`, спецкейс в `infer_call_expr` ДО обычной
      unification для `ввод_вывод::печать`/`строка`. Fallback — новый
      `value_to_display_string` (vm.odin, зеркалит `value_equals` по
      покрываемым Value-вариантам). Structural dump БЕЗ имени
      типа/полей (нет RTTI) — известное ограничение, не баг. 3 e2e-теста
      с РЕАЛЬНОЙ проверкой stdout (`run_code_capture_stdout` — временная
      подмена `os.stdout`). `odin test ./core` 96/96; native/lsp/wasm
      чисто
- [x] **Арифметика** (`+`/`-`/`*`/`/` overload) — 4 раздельных интерфейса
      (Складываемое/Вычитаемое/Умножаемое/Делимое; не один, как Ord —
      +-*/ мат. независимы). Self-фикс расширен на return_type
      (сложить/... возвращают Self, не примитив, в отличие от
      сравнить/равно). `.Plus` (Число+Число/Строка+Строка) не тронут,
      sugar встал ПОСЛЕ обеих проверок; Minus/Star/Slash вынесены в
      `infer_arithmetic_op`. Codegen — реюз `.Method_Struct`-паттерна.
      4 e2e-теста. `odin test ./core` 93/93; native/lsp/wasm чисто
- ~~По-умолчанию (Default)~~ — ВЫБРОШЕНО. `Массив.заполнить(N)`
      (единственный названный потребитель) не существует в stdlib —
      проверено grep'ом, мотивация была спекулятивной
- [x] **Копируемое (Clone)** — `=` НЕ трогается (авто-копирование на
      присваивании отдельно обсуждено и отклонено — слишком большой
      scope, ломает reference semantics как базовую модель языка).
      `.клонировать()` — обычный прямой вызов метода (НЕ operator
      sugar) — оказался бесплатным на существующей generic interface-
      dispatch инфраструктуре (Стадия 6), подтверждено эмпирически
      ДО реализации. Self-возврат уже покрыт Арифметики-фиксом
      (`interface_method_types_match`). Глубина — НЕ auto-derive, тело
      метода пишется руками (рекурсивные вызовы `.клонировать()` на
      вложенных полях). `prelude_copyable_sym` заведён для будущей
      Стадии 24 (copy-on-send). 2 e2e-теста. `odin test ./core`
      103/103; native/lsp/wasm чисто
- ~~Хешируемое (Hash)~~ — ВЫБРОШЕНО. Investigation (тот же паттерн, что
      По-умолчанию/Печатаемое): `Соответствие` — НЕ хеш-таблица в рантайме,
      `map_find_index` (vm.odin:295) — линейный перебор с `value_equals`.
      Единственный реальный блокер struct-ключей — typecheck whitelist
      `is_valid_map_key_type` (`.Number || .Bool || .String`), `value_
      equals` УЖЕ умеет структуры/перечисления рекурсивно. Интерфейс
      "Хешируемое" без хеш-таблицы под ним бессмысленен — relax
      whitelist (1 строка) при реальной нужде, настоящая хеш-таблица —
      отдельный VM-perf проект, не Стадия 23
- [x] **Итерируемое (Iterable)** ✅ — реализована. Один prelude-интерфейс
      `Итерируемое[T] { следующий() -> Опция(T) }`, контейнер сам себе
      итератор (мутирует состояние через `это.поле = ...`). `For_In_Stmt`
      — новый AST-узел (parser.odin), for-in БОЛЬШЕ НЕ десахаривается на
      parse-time — резолвится/типизируется обычно, `infer_for_in_stmt`
      (type_cheker.odin) решает fast-path (`.Array`) vs iterator-protocol
      (`.Struct` implements Итерируемое) vs error (включая восстановленный
      `.Map`-hint про `.записи()`), пишет решение в `ctx.for_in_infos`.
      `compile_for_in_stmt` (compiler.odin) эмитит байткод напрямую:
      fast-path — тот же паттерн, что раньше строило десахаривание;
      iterator-protocol — повторный `.следующий()` + `.Match_Tag`/
      `.Get_Variant_Field` (те же опкоды, что `выбор`, без синтетического
      Match_Expr). Оба пути через `Loop_Context` — прервать/продолжить
      работают как у While_Expr. Найден и исправлен баг (не архитектурный)
      — fast-path exit-check имел обратную полярность (Equal вместо
      Equal+Negate) — пойман полным прогоном e2e-тестов, не investigation'ом.
      4 новых e2e-теста + все 9 существующих for-in тестов прошли (1 hint-
      сообщение восстановлено явно). `odin test ./core` 109/109;
      native/lsp/wasm чисто, доп. проверено вживую через бинарник.
      Доработка: пользовательский вопрос вскрыл искусственный запрет
      `для (a, b) в ...` для Iterator_Protocol — T-тупл уже типизировался
      бы корректно, деструктуризация добавлена тем же паттерном, что у
      fast-path (`Массив((К,З))`). 1 новый e2e-тест. `odin test ./core`
      110/110. Подтверждено следующим вопросом ("а структура/ADT?") — T
      уже поддерживал ЛЮБОЙ kind без изменений кода, добавлено 2 теста
      (struct-элемент, ADT-элемент с `выбор` в теле). `odin test ./core`
      112/112
- ~~Хешируемое (Hash)~~ — ВЫБРОШЕНО (см. запись выше в этом же списке).

---

## Стадия 28 ✅ — generic-интерфейсы

Refs: [ROADMAP §Стадия 28](ROADMAP.md#стадия-28--generic-интерфейсы).

Жёсткий prerequisite для Итерируемого (Стадия 23) — закрыт. Оказалось
значительно проще исходной оценки: try_generalize/scheme для интерфейсов
НЕ понадобился вообще (ключевая находка — `instantiate_type` не имеет
`case .Interface`, типы этого кода проходят НЕТРОНУТЫМИ, Self-identity
переживает подстановку T автоматически). T выводится ИМПЛИЦИТНО за
каждый `реализация`-блок из конкретных типов impl'а — БЕЗ explicit-
инстанциации синтаксиса (`Итератор(Число)` нигде не пишется, ни в impl-
блоках, ни как аннотация типа — сознательно не реализовано, не нужно).

- [x] `core/parser.odin:78-83`/`770+` — `Interface_Decl.type_params` +
      `parse_interface_decl` читает `[T]`
- [x] ПРОХОД 1 (~1351) — `generic_origin` симметрично Struct/Enum
- [x] ПРОХОД 2 (~1456) — резолв `interface_methods` в
      `make_decl_type_params`/`current_type_params`-scope, БЕЗ
      `try_generalize` (не нужен)
- [x] Проверка контракта impl'а (ПРОХОД 3, ~1690) — свежая InferVar на
      T через `instantiate_type` ПЕРЕД каждой проверкой (не даёт T
      первого impl'а "зацементироваться" для последующих)
- [x] `interface_method_types_match` — `types_are_equal` → `unify_types`
      для не-Self частей (для не-generic интерфейсов ведёт себя
      идентично; для generic — связывает T)

3 e2e-теста (одна реализация; КЛЮЧЕВОЙ — два impl'а с разными T без
cross-contamination; негатив — нарушение формы контракта). `odin test
./core` 106/106 (0 регрессий на 6 ранее сделанных не-generic
интерфейсах). native/lsp/wasm чисто.

**Prerequisite**: Стадия 7 (Generics) — фактически готова, это —
недостающий кусок её охвата.

---

## Стадия 29 ✅ — литеральные шаблоны в `выбор`

Refs: [ROADMAP §Стадия 29](ROADMAP.md#стадия-29--литеральные-шаблоны-в-выбор).

`Pattern_Literal` был в AST давно, но парсер его никогда не создавал
(любой не-Ident токен — сразу parse error), `classify_pattern` безусловно
репортил "пока не поддерживаются", `infer_match_expr` требовал
`.Enum`-subject строго — `выбор` на Число/Строка/Булево был недостижим
целиком.

- [x] `core/parser.odin` — `parse_pattern`: 3 новых `if`-ветки
      (Number/String/Boolean)
- [x] `core/resolver.odin` — `resolve_pattern`'s `Pattern_Literal`-кейс
      резолвит `p.value` вместо ошибки
- [x] `core/type_cheker.odin` — `Match_Arm_Kind.Literal` +
      `Pattern_Info.literal_expr`; `classify_pattern` типчекает литерал
      против `expected_type`; `infer_match_expr` — Enum-only gate
      расширен на Number/String/Bool; `check_match_coverage` — Bool
      получает НАСТОЯЩУЮ exhaustiveness (2-элементный `bool_covered`,
      `_` не обязателен при покрытых истина+ложь), Number/Строка требуют
      обязательный catch-all (домен неперечислим)
- [x] `core/compiler.odin` — `compile_pattern`'s `.Literal`-кейс:
      `.Equal` + `.Jump_If_False`, БЕЗ нового опкода (переиспользует
      структурное сравнение оператора `==`, Стадия 22)
- [x] Бесплатный бонус: литеральные шаблоны работают как под-шаблоны
      внутри `Событие.Клик(1, y)` — `classify_pattern` уже рекурсивен

**Отклонено**: отрицательные числовые литералы (`-1 -> ...`) — реализация
была написана и убрана после того, как ручная трассировка (не Explore)
нашла причину непонятной ошибки парсинга: `parse_match_expr` парсит
subject без newline-aware терминации, `выбор x\n-1 -> ...` неотличимо от
`x - 1` на уровне токенов (ведущий `-` одновременно валиден как
префиксный унарный минус И инфиксное вычитание). Не полумера — явное
отсутствие фичи лучше, чем ловушка на конкретной комбинации subject +
первая ветка.

7 e2e-тестов (Число+`_`, Строка+биндер-catchall, Булево БЕЗ `_`
exhaustive, литерал в Constructor-подшаблоне, 3 негативных). `odin test
./core` 130/130 (0 регрессий). native/lsp/wasm чисто.

---

## Стадия 30 ✅ — деструктуризация в `пер`/`конст`

Refs: [ROADMAP §Стадия 30](ROADMAP.md#стадия-30--деструктуризация-в-перконст).

Естественное продолжение Стадии 29 в том же разговоре. Две формы, обе
позиционные: `пер (a, b) = кортеж` (тупл) и `пер Тип(a, b) = значение`
(структура, по порядку объявления полей). `конст (a, b) = ...` тоже
работает — `is_const` пробрасывается на каждое имя бесплатно.

- [x] `core/parser.odin` — `Let_Stmt.names`/`.destructure_type`,
      `parse_let_stmt` разбирает `(a, b)` и `Тип(a, b)`
- [x] `core/resolver.odin` — `let_destructure_syms` (та же форма, что
      `for_in_names_syms`), символ на каждое имя
- [x] `core/type_cheker.odin` — `infer_let_destructure_stmt`: тупл-ветка
      (`.Tuple` + длина), структур-ветка (`.Struct` + имя + число полей)
- [x] `core/compiler.odin` — `Let_Stmt`-кейс: RHS в temp slot,
      `.Get_Property`(i) + `.Set_Local` на каждое имя — БЕЗ нового
      опкода, тот же приём, что `compile_for_in_stmt` уже применяет
- [x] `core/position.odin` — `collect_local_symbols_stmt` видит
      деструктурированные имена (LSP-автодополнение)

5 e2e-тестов (тупл, структура, `конст`-immutability, 2 негативных —
arity mismatch, wrong struct type). `odin test ./core` 135/135 (0
регрессий). native/lsp/wasm чисто.

---

## Стадия 31 ✅ — структурные конструктор-шаблоны в `выбор`

Refs: [ROADMAP §Стадия 31](ROADMAP.md#стадия-31--структурные-конструктор-шаблоны-в-выбор).

Запрос: объединить `выбор` и деструктуризацию — `выбор точка { Точка(1,
x) -> ...; Точка(_, _) -> ... }`. `Pattern_Constructor` теперь работает
и на структурах, не только enum-вариантах — по ИМЕНИ ТИПА, поля по
порядку объявления, полноценные под-шаблоны (не только имена, как у
`пер`-деструктуризации Стадии 30).

- [x] `core/type_cheker.odin` — `Match_Arm_Kind.Struct_Constructor`;
      `classify_pattern`'s `Pattern_Constructor`-кейс: новая struct-ветка
      (имя + число полей) перед enum-веткой; `infer_match_expr` gate
      расширен на `.Struct`; `check_match_coverage` — `.Struct_
      Constructor` с всеми-wildcard подшаблонами = catch_all (как голый
      `_`), иначе требует финальную catch-all ветку
- [x] `core/compiler.odin` — `compile_pattern`'s `.Struct_Constructor`:
      БЕЗ `.Match_Tag` (одна форма, нечего сравнивать), сразу
      `.Get_Property` + рекурсия — тот же приём, что пер-деструктуризация

Известное консервативное упрощение (унаследовано от Стадии 25/29, не
регрессия): вложенный конструктор-под-шаблон всегда "не покрывает
целиком", даже если сам исчерпывающий — та же аппроксимация, что уже
была у `.Literal`/`.Constructor` под-шаблонов.

4 e2e-теста (полный пример из запроса, 3 негативных). `odin test ./core`
139/139 (0 регрессий). native/lsp/wasm чисто.

---

## Стадия 32 ✅ — `Целое`: отдельный целочисленный тип

Refs: [ROADMAP §Стадия 32](ROADMAP.md#стадия-32--целое-отдельный-целочисленный-тип).

Запрос: добавить `Целое` рядом с `Число` (НЕ переименование). На
рантайме то же f64-представление — различие только на уровне типов.

- [x] `Type_Kind.Integer`/`TY_INT` + `BASE_TYPES` запись
- [x] Литералы — Число по умолчанию, Целое только явно (первый проход —
      наоборот — вызвал массовую регрессию, откачен; см. ROADMAP —
      обсуждался и отклонён proper InferVar-default механизм как
      избыточная сложность для узкого выигрыша)
- [x] `check_expr`: `Number_Expr`/`Unary_Expr`(унарный минус)/
      `Binary_Expr`(+/-/*, нужно для составных Целое-контекстных
      выражений типа `длина(x) - 1`) — литерал/составное выражение
      сужается до Целое по контексту
- [x] `widen_num_literal_to_int` — литерал-сосед Целое-операнда в
      бинарных операторах тоже становится Целое (`x + 5` при `x: Целое`)
- [x] `/` на Целое/Целое — усечение к нулю (C/Rust/Go, не Python-флор),
      новый опкод `.Int_Divide`, опкод выбирает компилятор по
      статическому типу операнда
- [x] `%` — новый токен/оператор, только Целое, новый опкод `.Modulo`
- [x] `выбор` на Целое-subject — literal patterns, как у Число/Строка
      (Стадия 29), обязательный catch-all
- [x] Индекс массива/строки — Целое строго (отдельный запрос в этом же
      раунде): `infer_index_expr`, `длина()`/`.длина()`,
      `.получить(индекс,...)`/`.есть(индекс)`, числовой диапазон `для
      i = A по B` (счётчик+граница Целое — парсер добавляет аннотацию
      синтетическим Let_Stmt'ам), `строки.срез`/`строки.найти`,
      новый builtin `строки.из_целого` (нет overloading — `из_числа`
      не годится для Целое-аргумента)
- [x] `is_valid_map_key_type` — забытый кейс, `Целое` не был валидным
      ключом карты, поправлено заодно
- [x] Стандартная библиотека под новую строгость: `std/коллекции.ps`,
      `std/кодирование/json.ps`, `std/кодирование/toml.ps`,
      `std/сеть/http.ps` — счётчики/позиции/длины → Целое
- [x] `test.ps` — примеры под Целое-длину/-счётчик, новая
      `проверка_целых()`; `docs/src/language/basic-types.md` — новый
      раздел «Число и Целое»; `collections.md`/`control-flow.md`
      поправлены

Найденный по ходу баг (не регрессия этой стадии, а свежий баг в НОВОМ
коде текущей стадии): `&Type_Ident{...}` composite-literal-address-of в
парсере — стековая аллокация в Odin, не heap; указатель дальше терялся,
segfault при чтении в резолвере. Фикс: `new(Type_Ident)`.

`odin test ./core` — 139/139 (0 регрессий, 5 существующих e2e-тестов
переписаны под Целое). native/lsp/wasm чисто. `test.ps`/`test_toml.ps`/
`test_http.ps` + все 4 сетевых/кодирующих fixture — вручную прогнаны.

---

## Стадия 33 ✅ — Bounded traits: trait bounds на type-параметрах generic-функций

Refs: [ROADMAP §Стадия 33](ROADMAP.md#стадия-33--bounded-traits-trait-bounds-на-type-параметрах-generic-функций).

Запрос: `функ f[T: Сравниваемое](...)` — T ограничен списком
интерфейсов через `+`, внутри тела `x < y`/арифметика/`==` работают как
sugar. Grilled (три раунда): bound-синтаксис (несколько через `+`),
scope (только функции, не структуры/интерфейсы), диспатч
(**мономорфизация**, не рантайм-диспатч по type-тегу).

- [x] `core/parser.odin` — `Function_Decl.type_param_bounds`,
      `parse_function_type_params` (только функции)
- [x] `core/type_cheker.odin` — `Type.required_interfaces`,
      `make_decl_type_params` bounds-параметр (резолв имён интерфейсов,
      kind==.Interface проверка)
- [x] `type_satisfies_interface`/`primitive_satisfies_interface` —
      единая точка, примитивы (Число/Целое/Строка) удовлетворяют
      "родным" bound'ам без impl-блока (иначе T:Сравниваемое отказал бы
      Числу); Равнозначное СОЗНАТЕЛЬНО не в fallback'е (opt-in override,
      универсальный fallback дал бы sugar-путь на структуры без impl —
      живой баг, пойман тестами)
- [x] 5 sugar-гейтов в `infer_binary_expr` — kind-гейт расширен на
      `.InferVar`, `type_satisfies_interface` вместо
      `implements_prelude_interface`
- [x] `ctx.in_abstract_generic_body` — отличает "рекурсия/вложенный
      generic-вызов внутри ЕЩЁ абстрактного тела, не diagnostic" от
      "вызывающий код реально не вывел тип, настоящая ошибка"
- [x] `core/ast_clone.odin` (новый) — `clone_expr`/`clone_stmt`/
      `clone_type_node` (19+7+6 вариантов) — нужен, т.к. `ctx.node_
      types`/`ctx.call_infos` ключуются ПО УКАЗАТЕЛЮ узла, повторный
      typecheck ТЕХ ЖЕ узлов с разным T перезаписал бы прошлую
      инстанциацию
- [x] `core/monomorphize.odin` (новый) — `ctx.generic_call_
      instantiations`, `infer_bounded_generic_call` (отдельная ветка,
      своя `instantiate_scheme_with_subst`), `build_instantiation_key`
      (человекочитаемый `"f$Число"`, не pointer-based, как у generic_
      instance_cache), `monomorphize_one` (клон → resolve_function_body
      → typecheck с T напрямую подставленным в current_type_params →
      compile → registry), `monomorphize_program` (fixed-point driver,
      снимок необработанных ключей на каждой итерации — рекурсия
      добавляет новые записи ВО ВРЕМЯ обработки, обход+мутация одной
      map одновременно была бы UB)
- [x] `core/compiler.odin` — `monomorphize_program` МЕЖДУ pass 1
      (hoisting) и pass 2 (тела) — не ПЕРЕД pass 1 целиком (живой баг,
      первая версия ставила ДО hoisting'а, клоны не находили обычные
      методы типа `.сравнить()` в registry); bounded generic
      `Function_Decl` исключены из pass 1/2; call site — ключ
      инстанциации вместо `symbol_registry_key`

Побочная находка — **серьёзный pre-existing баг, не регрессия этой
стадии**: `core/resolver.odin`'s `resolve_program` создавала `Module`
стековым композитным литералом, `Symbol.module` хранит `^Module` на
него — dangling pointer сразу после возврата из `resolve_program`.
Молчал годами (ничего раньше не читало `Symbol.module` так поздно в
pipeline'е); `monomorphize_one` — первый код, дочитывающийся до
`symbol_at(...).module.path` на этапе КОМПИЛЯЦИИ. Тот же класс бага,
что stack-escape в Стадии 32. Фикс: `new(Module)`, как везде в
`module_loader.odin`.

Известное ограничение (сознательно, отложено): только generic-функции —
bounded generic-структуры/интерфейсы вне scope.

4 новых e2e-теста (primitive+struct dispatch в одной программе с
разными скомпилированными версиями; негативный без impl; multi-bound с
недостающим интерфейсом; рекурсия). `odin test ./core` — 143/143 (0
регрессий). native/lsp/wasm чисто.

---

## Стадия 34 ✅ — Рекурсивная exhaustiveness для вложенных конструктор-шаблонов

Refs: [ROADMAP §Стадия 34](ROADMAP.md#стадия-34--рекурсивная-exhaustiveness-для-вложенных-конструктор-шаблонов).

Закрывает известное ограничение из `language-fails`, унаследованное и
трижды продлённое (Стадия 25 → 29 → 31): вложенный Constructor/Struct_
Constructor под-шаблон ВСЕГДА считался "не покрывает", даже если сам
исчерпывающий (`Событие.Клик(Точка(_, _))`).

- [x] `Pattern_Info` — два поля вместо одного: `fields_fully_covered`
      ("тег уже зафиксирован, покрыты ли ЕГО поля") vs `is_exhaustive`
      ("покрывает ли шаблон ВЕСЬ домен своего типа" — для Constructor
      требует variant_count==1, нужен когда шаблон сам под-шаблон
      родителя)
- [x] `classify_pattern` — считает оба поля снизу вверх рекурсивно во
      всех ветках (Pattern_Ident/Pattern_Constructor × Struct/Enum)
- [x] `check_match_coverage` — `.Constructor`/`.Struct_Constructor`
      читают `pi.fields_fully_covered` вместо поверхностной проверки
      "любой sub.kind даёт false"

Живой баг в НОВОМ коде (не регрессия): первая версия слила оба понятия
в одно поле с гейтом `variant_count == 1`, что сломало ГОЛЫЕ (без
скобок) варианты-теги на верхнем уровне (`covered[tag]` требовал
variant_count==1, хотя top-level ветка должна засчитываться независимо
от общего числа вариантов — разные вопросы). Поймано всем test suite'ом
(24 упавших теста), разделено на два поля.

Известный смежный, НЕ исправленный здесь пробел (не регрессия,
существовал и до этой стадии — подтверждено тем же тестом на простом
не-вложенном Constructor): частичная ветка после уже полностью
покрывающей ветку того же тега не помечается недостижимой.

2 новых e2e-теста + пример в `docs/src/language/enums-and-match.md`.
`odin test ./core` — 145/145 (0 регрессий после фикса выше). native/
lsp/wasm чисто.

---

## Стадия 35 ✅ — Именованные поля в структурных шаблонах

Refs: [ROADMAP §Стадия 35](ROADMAP.md#стадия-35--именованные-поля-в-структурных-шаблонах).

Второй pattern-matching пункт из `language-fails` ("позиционный матчинг
разросся по площади поражения") — не полностью (деструктуризация
`пер Тип(a, b) = ...` вне scope по запросу, только match-шаблоны).
Grilled: синтаксис `Тип(имя: под-шаблон)` (тот же `:`, что у полей
структуры), частичная форма разрешена.

- [x] `Pattern_Constructor.field_names: [dynamic]string` (параллельно
      `args`, пусто = позиционная форма, нулевой риск регрессии)
- [x] `core/token.odin` — `peek_second_token` (двухтокенный lookahead),
      парсер решает форму по ПЕРВОМУ аргументу (`Ident Colon` впереди
      однозначно сигналит именованную форму, неоднозначности нет)
- [x] Только у структур — у enum-вариантов нет имён полей
      (`Variant_Decl.types`, не именованные поля), явный отказ в
      `classify_pattern`
- [x] Частичность: `sub_patterns` фиксированной длины (по числу полей,
      позиционно), неупомянутые поля — неявный `Pattern_Info{kind =
      .Wildcard, is_exhaustive = true}`, не сужают exhaustiveness
- [x] `compile_pattern` (compiler.odin) НЕ изменён — видит тот же
      позиционный `sub_patterns`, про имена полей не знает

6 новых e2e-тестов (частичное совпадение; все явно wildcard = catch-all;
неизвестное поле; смешивание форм; enum-вариант отказ). `docs/src/
language/enums-and-match.md` + `test.ps` (`классифицировать_точку_
именованно`). `odin test ./core` — 150/150 (0 регрессий). native/lsp/
wasm чисто.

---

## Стадия 44 ✅ — Link-примитив (`связать`)

Refs: [ROADMAP §Стадия 44](ROADMAP.md#стадия-44--link-примитив-связать).

По запросу ("давай link-примитив") — закрывает последний из трёх
крупных пунктов в `language-fails` после Стадии 43 (временное окно
лимита осталось — требует отдельного time-модуля с нуля).

- [x] `связать(процесс: Процесс(T)) -> Пусто` — двусторонняя связь,
      крах ЛЮБОЙ стороны каскадно завершает другую, штатное завершение
      НЕ каскадирует (тот же принцип, что у Erlang `normal` exit)
- [x] Сознательно БЕЗ Erlang-style `trap_exit` — `наблюдать`
      (уведомление) и `связать` (уведомление + смерть) уже два разных
      примитива, третий переключатель избыточен
- [x] `terminate_process` — общая функция, устраняет дублирование между
      `run_scheduler`'s `.Completed`/`.Crashed` и `call_builtin`'s
      `"убить"` (было продублировано в Стадии 42)
- [x] Cycle guard (`if !target.is_alive do return`) — и защита от
      двойной обработки, И корректность двустороннего каскада (A↔B —
      завершение A рекурсивно вызывает B, чей каскад пытается вернуться
      к A, guard обрывает обратный виток)
- [x] Root ("старт()") запрещён и как цель, И как инициатор связи —
      асимметрия с `убить()` (та запрещает root только как цель) —
      иначе root мог бы попасть в чей-то `links` и получить
      непроцессируемый каскад
- [x] Самолинковка разрешена (в отличие от самоубийства через `убить()`)
      — безвредна благодаря тому же guard

Побочно найдена (НЕ пофикшена, вне scope) pre-existing флакующая пара
тестов (`test_printable_interface_used_by_print`/`test_non_printable_
struct_falls_back_to_structural_dump`) — общий `os.stdout` в `run_code_
capture_stdout` не потокобезопасен под параллельным test-ранером,
никак не связано с actor-model кодом.

6 новых e2e-тестов. `docs/src/language/processes.md` — раздел
"Двусторонняя связь". `odin test ./core -define:ODIN_TEST_THREADS=1` —
182/182 (0 регрессий). native/lsp/wasm чисто.

---

## Стадия 43 ✅ — `std/супервизор.ps` подключён к `убить()`

Refs: [ROADMAP §Стадия 43](ROADMAP.md#стадия-43--stdсупервизорps-подключён-к-убить).

По запросу ("выполни следующий шаг") — закрывает follow-up, явно
отложенный в Стадии 42: групповые стратегии теперь реально останавливают
выживших siblings, не осиротевают.

- [x] Третий метод интерфейса `остановить() -> Пусто` — не отдельный
      id-based kill (сохраняет ОДИН kill-механизм в языке)
- [x] Каждая task-структура получила `последний: Опция(Процесс(T))`
      поле — `запустить()` пишет `это.последний = Опция.Есть(proc)`,
      мутация видна на следующем вызове через тот же интерфейсный хэндл
      (структуры — reference-типы, подтверждено эмпирически)
- [x] `остановить()` вызывает `убить()` на запомненном хэндле — тихий
      no-op сам по себе для уже упавшего ребёнка, реальная остановка
      для выживших
- [x] Групповой рестарт: `задачи[i].остановить(); задачи[i].запустить()`
      для КАЖДОГО i в диапазоне без условного пропуска упавшего —
      `убить()` на мёртвой цели уже безопасен

`test_supervisor.ps` + 3 fixture-файла обновлены (новый метод + поле).
`docs/src/language/processes.md` — пример и параграф про ограничение
переписаны. Существующие e2e-тесты (Стадии 40-41) не менялись
содержательно, все проходят. `odin test ./core` — 176/176 (0
регрессий). native/lsp/wasm чисто.

---

## Стадия 42 ✅ — Kill-примитив (`убить`)

Refs: [ROADMAP §Стадия 42](ROADMAP.md#стадия-42--kill-примитив-убить).

По запросу ("продолжай реализацию"), grilled: из kill/link/динамические
дети выбран kill — закрывает честно задокументированное ограничение
Стадии 41 (групповые стратегии не могли по-настоящему остановить
выживших siblings). VM-примитив (в отличие от Стадий 40/41).

- [x] `убить(процесс: Процесс(T)) -> Пусто` — типобезопасен, зеркалит
      `наблюдать` по форме, `.Call_Builtin` (не suspend/resume)
- [x] Переиспользует очистку `run_scheduler`'s `.Completed`/`.Crashed`
      (is_alive=false, `notify_watchers`, очистка полей,
      `unordered_remove`) — синхронно внутри `call_builtin`
- [x] Явно разобрана безопасность мид-scheduler-loop мутации (`process
      := vm.processes[i]` — копия указателя, не индекса; худший случай
      — фейрность round-robin в рамках одного раунда, не краш)
- [x] Самоубийство запрещено (execute() не умеет прервать сам себя) —
      фатальная ошибка
- [x] Убийство "старт()" запрещено (особая семантика корневого
      процесса) — фатальная ошибка
- [x] Убийство мёртвого процесса — тихий no-op (симметрично отправить())

4 новых e2e-теста (убийство + уведомление + изоляция; мёртвая цель —
no-op; самоубийство — фатально; убийство старт() — фатально).
`docs/src/language/processes.md` — новый раздел "Принудительная
остановка". `odin test ./core` — 176/176 (0 регрессий). native/lsp/wasm
чисто.

**Осознанно не сделано**: `std/супервизор.ps` пока НЕ переписан на
`убить()` для честных групповых рестартов — требует либо третьего
метода в `ДочерняяЗадача` (снова breaking change), либо отдельного
id-based kill — оставлено явным будущим шагом.

---

## Стадия 41 ✅ — Супервизия: `ВсеЗаОдного`/`ОстальныеЗаОдним`

Refs: [ROADMAP §Стадия 41](ROADMAP.md#стадия-41--супервизия-стратегии-всезаодногоостальныезаодним).

По запросу ("продолжи с супервизией"), grilled: из 4 гапов после Стадии
40 выбраны restart-стратегии (one_for_all/rest_for_one) — чисто
библиотечная доработка `std/супервизор.ps`, без языковых/VM изменений.

- [x] Найдено и честно задокументировано ограничение: в panos нет
      kill-примитива — выжившие siblings при групповом рестарте не
      убиваются, а осиротевают (та же природа, что осиротевшие процессы
      после `старт()`, Стадия 24), новые спавнятся рядом
- [x] `Стратегия` (перечисление): `ОдинЗаОдного`/`ВсеЗаОдного`/
      `ОстальныеЗаОдним`, новый параметр `супервизировать` — breaking
      change сигнатуры (обновлены все существующие вызовы)
- [x] `макс_рестартов` — двойной смысл по стратегии (per-child cap у
      `ОдинЗаОдного`, единый групповой счётчик у остальных двух) —
      осознанно, не отдельные параметры
- [x] `обработать_краш` теперь возвращает `Целое` (новый групповой
      счётчик) — `Целое`-локаль не reference-тип в отличие от `Массив`,
      мутация невидима вызывающему без return-and-reassign
- [x] Единый цикл группового рестарта, `от = 0` (`ВсеЗаОдного`) или
      `от = найденный` (`ОстальныеЗаОдним`) — единственная разница между
      стратегиями

2 новых e2e-теста (`ВсеЗаОдного`/`ОстальныеЗаОдним`, group-restart до
лимита → `паника()`), 1 обновлён (новый формат сообщения). 2 новых
fixture-файла. `docs/src/language/processes.md` — раздел переписан под
три стратегии. `odin test ./core` — 172/172 (0 регрессий). native/lsp/wasm
чисто.

---

## Стадия 40 ✅ — Супервизия: cross-module `реализация` + `std/супервизор.ps`

Refs: [ROADMAP §Стадия 40](ROADMAP.md#стадия-40--супервизия-реализация-модульинтерфейс-для-тип--stdсупервизорps).

По запросу ("приступа к супервизии"), grilled: чистая std-библиотека
поверх `наблюдать`/`получить_сигнал`, только one_for_one, лимит-счётчик
без временного окна, `паника()` при исчерпании. Гетерогенность (дети
разных T, как в Erlang) потребовала ре-grilling — найден реальный
языковой блокер: `реализация Модуль.Интерфейс для Тип` не парсилась.

- [x] `Impl_Decl.interface_module` (parser.odin) + `parse_impl_decl`
      читает опциональную `.`-квалификацию перед `для`; квалификация
      без `для` — понятная синтаксическая ошибка
- [x] `type_cheker.odin` — резолв `iface_sym` с веткой на `interface_
      module`, переиспользует путь `case ^Type_Qualified:`
- [x] `std/супервизор.ps` — `ДочерняяЗадача` интерфейс (`запустить()`,
      `имя()`), `супервизировать(задачи, макс_рестартов_на_ребёнка)`
      one_for_one цикл, restart tracking по позиции (не id, id меняется
      на рестарте), transient-семантика (Нет не рестартует), `паника()`
      при исчерпании лимита
- [x] Фабрика без замыканий — `запустить()` содержит буквальный `запусти
      <функция>(...)`, конфигурация зашита при объявлении (у panos-лямбд
      нет захвата внешних локалей — проверено эмпирически)
- [x] Побочно найден pre-existing parser-квирк (`-1` после `конец` читается
      как продолжение предыдущего выражения) — обойдён через `возврат -1`
      в библиотеке, сама ambiguity не чинится (вне scope)

4 новых e2e-теста (позитив — cross-module impl + полный supervisor-цикл
через `run_module_file`/`testing.expect_assert`; 3 негатива — неизвестный
модуль, не экспортирует, квалификация без `для`). `docs/src/language/
interfaces.md` + `processes.md` — новые разделы. `test_supervisor.ps` +
`fixtures/supervisor_fixture_main.ps`. `odin test ./core` — 170/170 (0
регрессий). native/lsp/wasm чисто.

---

## Стадия 39 ✅ — Единая hard-reserved политика зарезервированных слов

Refs: [ROADMAP §Стадия 39](ROADMAP.md#стадия-39--единая-hard-reserved-политика-зарезервированных-слов).

По запросу ("приведи к единой политике" → "так может сделать это
keywords?" → явно подтверждено "всё целиком", grilled с предупреждением
о breaking change). Раньше три ad-hoc политики: жёсткие keyword'ы
лексера (никогда не затеняемы), `в` (for-in, вообще не резервировано,
text-compare), builtin-функции (`.Builtin`-символы, свободно
затеняемые — Стадия 24 явно ВВЕЛА эту затеняемость). Единая политика:
всё зарезервированное — hard-reserved, без исключений.

- [x] `в` → настоящий `Token_Kind.In` лексера (token.odin/lexer.odin),
      как `как`/`запусти` — `parse_for_stmt_into` проверяет kind, не
      текст
- [x] `RESERVED_BUILTIN_NAMES` — общий package-level список (8 имён),
      используется и `install_standard_symbols`, и новым `check_not_
      reserved`
- [x] `register_named_symbol` — убрано исключение `kind != .Builtin`,
      коллизия с builtin'ом теперь та же ошибка, что с user-decl
- [x] `check_not_reserved` — вызван в 6 местах регистрации ЛОКАЛЬНОГО
      `.Variable`-символа (параметры функций/лямбд, `пер`/`конст`,
      деструктуризация, for-in, pattern-биндеры) — эти места не шли
      через `register_named_symbol`, по умолчанию разрешают затенение
      внешних имён

Обратная совместимость сломана осознанно, найдено полным прогоном
`odin test ./core`: 10 переименований в `core/e2e_test.odin` (нейтральные
имена, не тестируют сами эти слова по существу) + **публичная**
`std/сеть/http.ps`'s `получить` → `запросить` (единственное изменение с
реальным API-эффектом, `получить_с_заголовками` не затронута — другой
идентификатор) + 3 зависимых файла (`test_http.ps`, `networking.md`,
`modules.md`) + `test.ps`/`enums-and-match.md` (тот же pattern-биндер
`в`, что в e2e-тестах).

`docs/src/language/basic-types.md` — раздел "Зарезервированные слова"
переписан (единая политика вместо "мягкий/жёсткий тир"). `odin test
./core` — 166/166 (0 регрессий после фиксов). `test.ps`/`test_toml.ps`/
`test_http.ps` — sanity. native/lsp/wasm чисто.

---

## Стадия 38 ✅ — Monitor-примитив (`наблюдать`/`получить_сигнал`) + изоляция крашей

Refs: [ROADMAP §Стадия 38](ROADMAP.md#стадия-38--monitor-примитив-для-actor-model-наблюдатьполучить_сигнал).

По запросу ("Давай с supervisor tree/monitor") — grilled: только сам
примитив (не supervisor tree со стратегиями рестарта — станет
panos-кодом поверх примитива позже). Изоляция крашей — ключевая находка
planning'а: без неё monitor видел бы только штатное завершение, а не
краши, что гораздо слабее Erlang'а.

- [x] `Exec_Result.Crashed` + `VM.crash_message` — тот же паттерн, что
      `.Suspended` у `.Receive`
- [x] 4 catchable-сайта переведены с `fmt.panicf` на `.Crashed`:
      `паника()` (единая точка — `.значение()`/`.ожидать()` и т.п. у
      Опции/Результата зовут её из PRELUDE_SOURCE, не 49 разрозненных
      panicf), `.Int_Divide`/`.Modulo` при 0, `.Get_Index`/`.Set_Index`
- [x] `run_scheduler`: `.Crashed` при i==0 — по-прежнему фатально (тот
      же текст, 3 существующих теста на `паника()` не регрессируют);
      при i!=0 — изоляция + рассылка сигнала наблюдателям; `.Completed`
      при i!=0 — тоже теперь рассылает сигнал (штатное завершение)
- [x] `Process_Value.watchers`/`.signals` (compiler.odin), `notify_
      watchers` хелпер (vm.odin)
- [x] `наблюдать(процесс)` — обычный `.Call_Builtin`, любой T; на уже
      мёртвую цель — немедленный синтетический сигнал
- [x] `получить_сигнал()` — свой опкод `.Receive_Signal` (suspend/resume
      как `.Receive`), фиксированный тип `(Целое, Опция(Строка))`
- [x] `.номер()` — новый метод на `Процесс(T)`, id для сравнения
      (`value_equals` не сравнивает `^Process_Value` по значению)
- [x] Найденный по ходу баг: deadlock-guard в `run_scheduler` проверял
      только `mailbox`, не `signals` — процесс на `получить_сигнал()`
      никогда не получал второй шанс. Исправлено (пойман первым
      smoke-тестом, живой дедлок)
- [x] GC: разметка `signals` в `mark_value`/`mark_roots` (gc.odin)

6 новых e2e-тестов (штатное завершение → (id, Нет); краш → (id,
Есть(причина)) без падения всей программы; деление на ноль/индекс за
границей в дочернем процессе изолируются; наблюдение за мёртвым
процессом — немедленный сигнал; несколько наблюдателей — все
уведомлены). `docs/src/language/processes.md` + `test.ps`
(`проверка_наблюдения`). `odin test ./core` — 166/166 (0 регрессий).
native/lsp/wasm чисто.

---

## Стадия 37 ✅ — Именованная/частичная деструктуризация

Refs: [ROADMAP §Стадия 37](ROADMAP.md#стадия-37--именованнаячастичная-деструктуризация).

По запросу ("Реши 2") — закрывает последний позиционный-only пункт из
`language-fails`: `пер Тип(a, b) = значение` был единственным местом
без именованной альтернативы (конструктор и шаблоны `выбор` её уже
получили в Стадиях 35-36). Синтаксис `:` (свой выбор, не `=`) —
деструктуризация семантически ближе к матчингу, чем к вызову. Может
быть ЧАСТИЧНОЙ (в отличие от именованных аргументов вызова).

- [x] `Let_Stmt.destructure_field_names: [dynamic]string` (параллельно
      `names`, пусто = позиционная форма, только для структуры, не
      тупла)
- [x] `parse_destructure_names(p, allow_named)` — тупл-ветка `false`,
      структурная `true`; тот же паттерн детекции (`Ident` + `.Colon`) и
      diagnostic при смешивании форм, что у Стадий 35/36
- [x] `Type_Ctx.let_destructure_field_indices: map[Stmt][dynamic]int` —
      параллельный массив РЕАЛЬНЫХ индексов полей (не полная
      перестановка AST, как у Call_Expr, — частичность не даёт
      переставлять массив другой длины)
- [x] `infer_let_destructure_stmt` переписан: валидация неизвестного
      имени поля / повтора имени для именованной формы, тождественные
      индексы для обеих позиционных форм
- [x] `compiler.odin`: кодогенерация деструктуризации читает
      `field_indices[i]` вместо сырого `i` как операнд `.Get_Property`

6 новых e2e-тестов (реордер; частичное извлечение; неизвестное имя/
повтор/смешивание форм — ошибки; тупл отклоняет именованный синтаксис).
`docs/src/language/structs-and-methods.md` — раздел «Именованная
деструктуризация». `test.ps` — `Игрок(здоровье: ..., имя: ...)` и
частичное `Игрок(координаты: ...)`. `odin test ./core` — 160/160 (0
регрессий). native/lsp/wasm чисто.

---

## Стадия 36 ✅ — Именованные аргументы в вызовах

Refs: [ROADMAP §Стадия 36](ROADMAP.md#стадия-36--именованные-аргументы-в-вызовах).

Прямое продолжение Стадии 35 — именованные АРГУМЕНТЫ на call site'ах
(не только поля в шаблонах). Grilled: везде (функции + конструкторы +
методы), без смешивания и без частичности. Синтаксис `=` (не `:`) —
по прямому указанию, та же нотация, что у `соответствие(ключ =
значение)`.

- [x] `Call_Expr.arg_names: [dynamic]string` (параллельно `args`, пусто
      = позиционная форма)
- [x] Парсер: `x = 1` как позиционное присваивание-выражение НЕ
      теряется по факту (Пусто нигде не может быть типом параметра —
      старая интерпретация никогда не типизировалась успешно)
- [x] `resolve_named_call_args` — ОДНА общая процедура, переставляет
      `e.args` в AST в порядок объявления ДО любой из ~8 веток
      разрешения вызова, дальше всё работает неизменённо
- [x] `symbol_to_func_decl` расширена на методы (раньше только
      топ-уровневые функции) — нужна для имён параметров метода
- [x] Известное ограничение: интерфейсные вызовы не поддержаны
      (`interface_methods` не хранит исходные имена параметров) —
      явная diagnostic

4 новых e2e-теста (функция+структура+метод в одном сценарии; смешивание/
неизвестное имя/повтор — ошибки). `docs/src/language/functions.md` +
`test.ps`. `odin test ./core` — 154/154 (0 регрессий). native/lsp/wasm
чисто.

---

## Стадия 24 ✅ (grilled — дважды пересмотрено, actor model) — lightweight processes (Elixir/Akka-style)

Refs: [ROADMAP §Стадия 24](ROADMAP.md#стадия-24-grilled--дважды-пересмотрено-actor-model--lightweight-processes-elixirakka-style).

**ЗАКРЫТА ПОЛНОСТЬЮ** — Task 43-49 реализованы, 8 e2e-тестов,
`odin test ./core` 123/123, native/lsp/wasm чисто (см. ROADMAP §Стадия
24 «Task 43-49» для деталей верификации).

ПЕРЕСМОТРЕНА ЦЕЛИКОМ вторым grilling-раундом: первый раунд спроектировал
CSP-style shared-memory `Канал(T)` + generic `дай`-yield корутины —
реальная мотивация оказалась "лёгковесные Elixir/Akka-like актёры", не
CSP. Actor model заменяет CSP-каналы и generic-генераторы полностью (оба
убраны из scope). Single-thread cooperative scheduler (`execute()`,
vm.odin:800 — frames/stack уже в куче, suspend/resume без asm/OS-fiber)
остаётся низкоуровневым примитивом ПОД actor-моделью, не меняется между
раундами.

**Решено (grilled, оба раунда)**:
- [x] Single-OS-thread cooperative, БЕЗ реального параллелизма —
      ПЕРЕСПРОШЕНО явно во втором раунде (после смены на actor-фрейминг)
      и подтверждено снова (BEAM был single-threaded per scheduler годами
      до SMP — actor/fault-tolerance ценность не требует параллелизма
      как предусловия)
- [x] Copy-on-send: автоматический REFLECTIVE deep-copy по умолчанию для
      ЛЮБОЙ структуры при отправке в mailbox — НЕ требует explicit
      `реализация Копируемое`; она — опциональный override для кастомной
      семантики. Примитивы/неизменяемые строки — без копии
- [x] Supervisor tree (restart-стратегии, link/monitor) — вне scope v1,
      отдельная будущая стадия поверх готового v1-примитива
- [x] Mailbox — строгий FIFO, НЕ selective receive (Erlang-style —
      известный источник багов, O(n)-скан, mailbox explosion)
- [x] Тело процесса — Erlang-style (рекурсивная функция + `выбор` на
      ADT-сообщение), НЕ Akka-style (мутабельный struct+метод) —
      продолжает уже принятое в языке (ADT + `выбор` с exhaustiveness)
- [x] Адресация — новый generic-тип `Процесс(T)` (НЕ переиспользует
      `Канал(T)` первого раунда — разная семантика). `запусти` теперь
      ВОЗВРАЩАЕТ `Процесс(T)` (раньше — fire-and-forget statement).
      `отправить(процесс, сообщение)` — обычная функция, не оператор.
      `получить()` — builtin, блокирует до следующего сообщения
- [x] Generic `дай`-генераторы — ПОЛНОСТЬЮ убраны из scope (не нужны)
- [x] Отправка мёртвому процессу — тихий no-op (Erlang-поведение), НЕ
      `Результат` (синхронная проверка живости всё равно гонка)

**Investigate (Explore проведён, находки записаны в ROADMAP §Стадия
24)**:
- [x] Компиляция `запусти`/`получить`/`отправить` — три разных
      механизма: `запусти` новый `nud()`-префикс + опкод `.Spawn`,
      `получить()` — bare-имя builtin (`BUILTIN_CTORS`-механизм) → опкод
      `.Receive`, `отправить(процесс, сообщение)` — обычная 2-арг
      builtin-функция без нового опкода
- [x] Типизация `Процесс(T)` как generic-типа — ТРЕТЬЯ ветка в
      `Type_Generic`-цепочке `resolve_type_node` (как `Массив`/
      `Соответствие`), НЕ через Struct/Enum `Type_Scheme`-механизм
- [ ] Reflective deep-copy механизм (для copy-on-send по умолчанию) —
      новый, отдельный от Копируемое; переиспользуем GC's value walker
      (gc.odin, уже обходит те же структуры для root-marking) — Task 47
- [ ] GC root-walking по множеству стеков процессов (gc.odin) — сейчас
      один `vm.stack`/`vm.frames`, тривиальный корень — Task 47
- [x] Mailbox — простая FIFO-очередь ([dynamic]Value) прямо полем на
      `Process_Value`, БЕЗ отдельного GC-объекта (упрощено от
      Explore-предложения отдельного `Mailbox_Value`)
- [x] Синтаксис `Процесс(T)` + `запусти`-как-выражение — `Spawn_Expr`
      (parser.odin), оборачивает `Call_Expr` (резолвер/typecheck/
      compiler переиспользуют существующие Call_Expr-пути через
      `e.call`, не дублируют логику)

**Реализация (Task 43-49, см. ROADMAP §Стадия 24 «Порядок работ» +
«Найдено по ходу»)**:
- [x] Task 43 — Value/Type foundation: `Process_Value` (compiler.odin),
      `Type_Kind.Process`/`new_process_type` (type_cheker.odin)
- [x] Task 44 — VM struct: `Exec_Result`, `VM.processes`, `new_vm()`
      строит старт() как `Process_Value` "процесс #0", `run_scheduler()`
      (round-robin, `has_run`-based skip, genuine-deadlock panic)
- [x] Task 45 — опкоды `.Spawn`/`.Receive` (compiler.odin Opcode enum,
      vm.odin execute())
- [x] Task 46 — парсер (`запусти`-префикс, `.Spawn`-токен, лексер) +
      typecheck (`Процесс(T)`, `получить`/`отправить` builtin'ы,
      `ensure_body_checked`-мемоизация для T процесса независимо от
      порядка деклараций, `infer_match_expr` unify-ветка для
      InferVar-subject через квалифицированные паттерны) + compiler
      (`.Spawn`-кодоген, `получить()` → `.Receive`, `отправить` →
      `.Call_Builtin`) + рантайм-обработчик `отправить` (vm.odin,
      copy-on-send пока БЕЗ реального deep-copy — Task 47). Найден и
      исправлен попутный баг: `install_standard_symbols` резервировал
      builtin-имена в общей global scope, конфликтуя с существующими
      user-функциями `получить`/`отправить` в 2 e2e-тестах — фикс:
      user-декларация может перетереть `.Builtin`-символ (обычное
      затенение). Сквозная проверка: spawn → send → suspend (deadlock
      корректно детектится, когда некому разбудить); негативные типы
      (`запусти` не-функции, `отправить` не-Процесс) — понятные
      diagnostics, не крэш.
- [x] Task 47 — `mark_roots` (gc.odin) теперь ходит циклом по
      `vm.processes`: mailbox каждого процесса (никогда не свопается,
      всегда актуален) + `.stack` только НЕ-текущих процессов (текущий
      уже учтён через `vm.stack` — `process.stack`-дескриптор может быть
      устаревшим относительно него сразу после append-реаллокации).
      `message_deep_copy` (vm.odin, адаптация `value_to_display_string`'а
      walker'а, visited теперь map ОРИГИНАЛ→КОПИЯ — сохраняет топологию
      циклов, а не просто обрывает обход) — новый `Call_Kind.Send_Copy`
      (type_cheker.odin): T реализует Копируемое → компилятор вставляет
      явный `.клонировать()` и эмитит внутреннее имя
      `отправить_без_копии` (НЕ настоящий `отправить` — иначе рантайм
      reflective copy исказил бы намеренно НЕ скопированные
      пользователем поля, см. Копируемое-комментарий в prelude.odin); не
      реализует → обычный `отправить`, рантайм сам обходит структуру.
      Проверено: mutation-after-send не искажает уже отправленное
      значение; explicit-Копируемое путь компилируется и выполняется без
      ошибок (raw reference-sharing путь vs явный `.клонировать()`-путь
      оба протестированы).
- [x] Task 48 — end-to-end интеграция scheduler'а. Найдено по ходу:
      Порядок работ п.6 подразумевал "получить() на своём mailbox
      старт() даёт ожидание ответа", но не было способа передать
      спавненному процессу СВОЙ адрес — добавлен `себя()` (bare
      builtin, тот же механизм что `получить`, возвращает `Процесс(T)`
      текущего процесса). Полный цикл (`запусти` → `отправить(...,
      себя())` → suspend на `получить()` у отправителя → удалённый
      `отправить` → resume → значение) протестирован end-to-end,
      воспроизводит ROADMAP-пример дословно.
- [ ] Task 49 — e2e тесты (перенести ad-hoc smoke-тесты в
      e2e_test.odin) + финальная верификация (odin test/lsp/wasm) +
      commit

`odin test ./core` 115/115 после Task 43-48 (0 регрессий). native/lsp/wasm
чисто.

---

## Стадия 25 ✅ — интерфейсы для перечислений

Refs: [ROADMAP §Стадия 25](ROADMAP.md#стадия-25--интерфейсы-для-перечислений).

- [x] typecheck guard снят (`target_type.kind == .Enum && d.interface_name
      != ""` в ПРОХОД 3) + `enum_type.implemented_interfaces`
      инициализация в ПРОХОД 1 (не было, в отличие от Struct)
- [x] `unify_types`/`types_are_equal`/`check_expr`'s интерфейс-коэрсия
      расширена с `left.kind == .Struct` на `|| .Enum` (3 site'а)
- [x] Рантайм: `Interface_Value.data` `^Aggregate_Value` → `Value`
      (compiler.odin); `.Cast_Interface` принимает Aggregate_Value ИЛИ
      Variant_Value (vm.odin); `.Set_Property` через интерфейс остаётся
      struct-only с понятной ошибкой (Variant_Value без settable-полей);
      `gc.odin` mark/sweep поправлен под новый тип поля
- [x] Найден и исправлен: `compiler.odin`'s `case ^Property_Expr:` —
      ранний `return` для безаргументного конструктора варианта не звал
      `maybe_emit_interface_cast` (payload-варианты через Call_Expr уже
      звали)
- [x] Найден и исправлен: `instantiate_type`'s `case .Enum:` не копировал
      `implemented_interfaces` при инстанциации generic enum'а (у
      `.Struct` уже был этот фикс из Стадии 7) — молча терялась
      реализация интерфейса при каждой инстанциации `Опция(T)`
- [x] Operator sugar (Ord/Eq/Арифметика/Печатаемое, Стадия 22/23)
      расширен на `.Enum` — 5 site'ов с `left_t.kind == .Struct`
- [x] Найден и исправлен (отдельно от enum-специфики): sugar-проверка
      "тот же тип" использовала `==`/`!=` (указатель) вместо
      `unify_types` — ложно отвергала нулевой-payload вариант generic-
      enum'а (`Опция.Нет()`, T не выводится из значения). Подтверждает
      исходный мотивирующий пример дословно: `Опция.Есть(5) <
      Опция.Есть(10)` и `Опция.Нет() < Опция.Есть(1)`

5 e2e-тестов. `odin test ./core` 115/115. native/lsp/wasm чисто.

---

## Стадия 26 (grilled, три раунда) — `panos mod`: встроенный пакетный менеджер

Refs: [ROADMAP §Стадия 26](ROADMAP.md#стадия-26-grilled-три-раунда--panos-mod-встроенный-пакетный-менеджер).

Подкоманды у `panos` (go mod style, один бинарник, нативный Odin) —
решено явно. НЕ отдельный бинарник `pan` (существующая заготовка
`/Users/gaidar/dev/panosiki/pan/`, 0 коммитов — неактуальна, план живёт
здесь). По ходу грилинга всплыл и закрыт крупный побочный вопрос "не
уйти ли с Odin вообще" (TLS-пробел в `core:net`) — разобран, отклонён,
решение осталось на Odin (см. ROADMAP).

**Решено**:
- [x] Fetch — HTTP-скачивание архива по git-host archive-ссылкам
      (`.../archive/refs/tags/vX.Y.Z.tar.gz`), НЕ git-subprocess, НЕ
      registry-сервер
- [x] Транспорт — [`laytan/odin-http`](https://github.com/laytan/odin-http)
      (HTTPS через OpenSSL, обычный `import`)
- [x] Формат архива — только `.tar.gz` (не zip) — свой TAR-контейнер-
      парсер (простой, ~1-2 дня) + существующий `core:compress/gzip`
- [x] Манифест парсит [`Up05/toml_parser`](https://github.com/Up05/toml_parser)
      (Odin TOML-библиотека, registry v1.2.0) — НЕ `std/кодирование/toml.ps`
      (тот panos-уровневый, манифест парсит нативный хост, не VM)
- [x] Найдено: `Up05/toml_parser` ОДНОНАПРАВЛЕННЫЙ — только parse/
      unmarshal, нет marshal/encode/write. Для записи `панос.lock`
      (и, возможно, `панос.toml` при `init`) нужен СВОЙ маленький
      TOML-writer — задача мала (узкий формат, шаблонный `fmt.fprintf`,
      не общий "TOML наоборот")
- [x] Разрешение версий — ПЛОСКИЙ список прямых зависимостей, БЕЗ
      транзитивного резолва/MVS (v1)
- [x] Версионирование — обычные semver git-теги, БЕЗ Go-style
      major-в-пути-импорта конвенции
- [x] Имена файлов — КИРИЛЛИЦА: `панос.toml`/`панос.lock`
- [x] Целостность — SHA-256 hash-lock в `панос.lock` (go.sum-style),
      проверка при установке

**Сделано заранее** (вне порядка работ, но уже готово):
- [x] `laytan/odin-http`/`Up05/toml_parser` завендорены в
      `external/odin-http`/`external/toml_parser` (plain tracked files,
      тем же способом что `external/back`) — `odin check` на оба чисто

**Investigate/реализовать (после решений выше — конкретные touch-точки)**:
- [ ] main.odin — новые subcommands (`panos mod init`/`get`/аналоги)
- [ ] Свой TOML-writer для `панос.lock`/`панос.toml` — `Up05/toml_parser`
      однонаправленный (только parse/unmarshal), писать самим
- [ ] Свой TAR-парсер — конкретная реализация (read-only, обычные
      файлы/директории)
- [ ] Формат `модули/`-vendoring layout для многофайловых пакетов

---

## Стадия 27 (grilled, один раунд) — `конст`: неизменяемые биндинги ✅

Refs: [ROADMAP §Стадия 27](ROADMAP.md#стадия-27-grilled-один-раунд--конст-неизменяемые-биндинги).

Новое ключевое слово `конст`, параллельное `пер` — запрещает
переприсвоение имени после объявления. НЕ deep immutability (поля
структуры через `x.поле = 5` по-прежнему мутируемы — `конст`
контролирует только сам биндинг, не то, на что он указывает).

**Решено**:
- [x] Уровень — binding-immutability (JS `const`/Kotlin `val`-style), не
      deep immutability. Дешевле, не трогает Set_Property/Set_Index,
      не требует протаскивать mutability через type checker

**Explore-находки (эмпирически, тестовыми прогонами через `run_code`)**:
- [x] Переприсваивание параметров функции УЖЕ работает сегодня — конст
      не трогает параметры, вне scope фичи
- [x] Shadowing в ТОМ ЖЕ scope УЖЕ запрещено резолвером ("Имя x уже
      объявлено") независимо от const/mut — конст наследует бесплатно
- [x] Shadowing во ВЛОЖЕННОМ scope УЖЕ работает (независимый Symbol на
      scope) — is_const корректен здесь без спецкейсов
- [x] LSP hover сейчас показывает ТОЛЬКО имя типа, без symbol-lookup —
      конст-префикс в hover был бы net-new доработкой, не правкой
      (вынесено опциональным шагом 9, не блокирует core-фичу)

**Порядок работ (реализовано)**:
1. [x] `core/lexer.odin:157` / `core/token.odin` — `"конст" -> .Const`
       (новый `Token_Kind`)
2. [x] `core/parser.odin:212` — `Let_Stmt.is_const: bool`
3. [x] `core/parser.odin:1146-1150` — `parse_stmt`: `.Let, .Const ->
       parse_let_stmt`
4. [x] `core/parser.odin:1412-1431` — `parse_let_stmt` читает, какой
       токен съеден, выставляет `is_const` (+ error-message теперь
       называет правильное ключевое слово вместо хардкода "пер")
5. [x] `core/resolver.odin:285-298`/`16-28` — `new_symbol`/`Symbol`
       получают `is_const: bool` (форма `is_pattern_binder`)
6. [x] `core/resolver.odin:710-720` — `Let_Stmt`-резолв передаёт
       `is_const = s.is_const`
7. [x] `core/type_cheker.odin:2749` — `case .Assign:` — если `e.left`
       `^Ident_Expr` с `Symbol.is_const`, diagnostic ПЕРЕД
       unify_types-проверкой. Property_Expr/Index_Expr вне проверки
8. [x] compiler.odin — без изменений (typecheck гейтит пайплайн)
9. [ ] (опционально, вне core-скоупа, НЕ сделано) LSP hover —
       конст-префикс, требует symbol-lookup в `handle_hover`
10. [x] e2e-тесты (core/e2e_test.odin): позитив
       (`test_const_binding_reads_like_normal_let`), негатив
       (`test_const_reassignment_is_error`), 2 regression
       (`test_function_params_still_reassignable`,
       `test_const_shadowing_nested_scope_still_works`)

`odin test ./core` — 100/100. native/lsp/wasm сборки чисты.

**Расширение (тот же раунд) — параметры функций/лямбд immutable по
умолчанию**:
- [x] Развёл 2 оси: запрет переприсвоения (реализовано) vs copy-on-call
      (пересекается с Копируемое, вне скоупа)
- [x] Kotlin/Swift-style — ВСЕ параметры immutable по умолчанию (не
      opt-in `конст` перед параметром), без opt-out на v1
- [x] `core/resolver.odin:515` (`resolve_function_body`) и `:867`
      (`Lambda_Expr`) — `new_symbol(..., is_const = true)`
- [x] BREAKING CHANGE проверен эмпирически — сломался только
      собственный regression-тест исходной Стадии 27 (переписан в
      `test_function_params_are_immutable_by_default` +
      `test_function_params_still_readable`), `std/*.ps` параметры
      нигде не переприсваивает (blast radius пуст)

`odin test ./core` — 101/101. native/lsp/wasm сборки чисты.

---

## Заметки

- `.claude/` и `CLAUDE.md` намеренно исключены из git (agent-context).
- При закрытии стадии — обновлять timestamp в `ROADMAP.md`.
- При изменении scope — синхронизировать оба файла (`ROADMAP.md` +
  `TASKS.md`).
