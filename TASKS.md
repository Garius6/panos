# Panos — Задачи

**Текущая стадия**: готовы 0, 1, 2, 3, 6, 10, 11, 12, 13, 14, 15, 16, 17
(10-17 — вне очереди), 5 частично (Symbol_Id + LSP completions/references/
rename; Type_Id отложен). Следующие разблокированные: 4 (FFI-A), 7
(Generics, требует 6 ✓), 8 (FFI-B, требует 1 ✓ — finalizers теперь
возможны). Type_Id/SoA (остаток Стадии 5) — отдельная перформансная
задача без явного триггера.
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

Refs: [ROADMAP §Стадия 4](ROADMAP.md#стадия-4--ffi-фаза-a-raylib-demo-3-дня).

Prerequisite: нет. Независимо.

- [ ] `raylib_bindings.odin` — foreign import + ~50 функций
- [ ] Panos-модуль `графика` в stdlib
- [ ] Demo: pong / snake в `demos/`
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

- [ ] Constraint generation pass (`Equal(t1, t2)` и т.п., без solve)
- [ ] Constraint solver (batch unification над накопленными constraint'ами)
- [ ] Phase A: implicit rank-1 для лямбд
- [ ] Phase B: `функ имя[T](x: T) -> T`
- [ ] Phase C: generic struct/interface
- [ ] Phase D: generic ADT
- [ ] Phase E: `реализация Список[T]`
- [ ] Phase F: prelude cleanup (Опция/Результат как user-declared ADT)

---

## Стадия 8 — FFI фаза B: dynamic

Refs: [ROADMAP §Стадия 8](ROADMAP.md#стадия-8--ffi-фаза-b-dynamic-3-4-недели).

Prerequisite: Стадия 1 + Стадия 6.

- [ ] Грамматика `внешний "libc" функ ...`
- [ ] FFI-типы (`Число_32`, `КСтрока`, `Указатель(T)`, `ff_структура`)
- [ ] libffi static-linked binding
- [ ] Type descriptor builder (Panos type → ffi_type)
- [ ] Primitive marshalling
- [ ] Struct-by-value marshalling
- [ ] `Call_Foreign` opcode + VM handler
- [ ] Callback'и через ffi_closure
- [ ] Memory ownership аннотации + GC finalizers
- [ ] SIGSEGV recovery
- [ ] Обёртка raylib на Panos-стороне (замена FFI-A)
- [ ] Обёртка libc `фс` (миграция host stdlib)

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
      было отложено). module_loader.odin (5 panicf) по-прежнему отложено:
      file-not-found/circular import — это ошибки окружения, а не текста
      программы, накопление diagnostics для них не даёт очевидной пользы

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

## Заметки

- `.claude/` и `CLAUDE.md` намеренно исключены из git (agent-context).
- При закрытии стадии — обновлять timestamp в `ROADMAP.md`.
- При изменении scope — синхронизировать оба файла (`ROADMAP.md` +
  `TASKS.md`).
