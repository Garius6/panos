# Implementation Plan: Полный перенос интерпретатора Panos на Zig

**Branch**: `010-zig-migration` | **Date**: 2026-08-03 | **Spec**: [spec.md](./spec.md)
**Input**: Утверждённая спецификация полного переноса с Odin на Zig.

> Рабочая копия остаётся на ветке `main`: создание ветки не было запрошено.
> Артефакты плана намеренно записаны напрямую в `specs/010-zig-migration/`.

## Summary

Создать самостоятельную реализацию Panos на Zig в каталоге `zig/`, сохраняя
Odin-реализацию только как read-only эталон до cutover. Миграция начинается с
нормализованного набора conformance-тестов, затем вертикальными срезами
переносит frontend, семантику, bytecode VM с tracing GC, native-адаптеры,
два WASM-пути и LSP. Каждый срез проходит сравнение с эталоном до перехода к
следующему; финальный cutover убирает Odin из основных команд сборки и CI.

## Technical Context

**Language/Version**: Zig `0.16.0`, закреплённая release-версия; master не
используется.
**Primary Dependencies**: Zig standard library; существующие вендоренные
статические `libffi` и `sqlite3`; browser host JavaScript; `wasmtime` только
для необязательных AOT-WASM integration-тестов.
**Storage**: Файловый граф `.ps`-модулей, встроенная прелюдия/stdlib и
временные native-ресурсы; отдельная БД у интерпретатора отсутствует.
**Testing**: `zig test` для unit/integration; общий compatibility manifest;
дифференциальный runner с Odin до cutover; WASM smoke/differential tests с
wasmtime и browser harness.
**Target Platform**: Native Darwin ARM64, Linux AMD64, Windows AMD64;
browser `wasm32-freestanding`; AOT runtime additionally `wasm32-wasi` для
wasmtime-тестов.
**Project Type**: Компилятор, bytecode VM, AOT-WASM emitter и LSP-сервер.
**Performance Goals**: Сначала семантическая эквивалентность; до cutover
зафиксировать cold-start, пиковую память и время полного conformance-прогона
как baseline, без обещания оптимизаций до его достижения.
**Constraints**: Финальные поставляемые команды не вызывают Odin; язык,
CLI, стандартная библиотека и публичные LSP-возможности не меняются; Odin
исходники не редактируются ради упрощения нового пути; нативные C ABI и
browser host imports сохраняют документированные контракты.

## Constitution Check

*GATE: пройден до research и повторно проверен после проектирования.*

- **I. Think Before Coding**: Зафиксирован самостоятельный Zig-путь, а не
  «гибридный» вызов Odin из Zig. Главные риски (GC, async VM, два WASM-пути,
  FFI) разобраны в [research.md](./research.md) и закрываются отдельными
  gate’ами до масштабного переноса.
- **II. Simplicity First**: Не добавляются синтаксис, оптимизации или новые
  таргеты. Сохраняются существующие промежуточные границы (frontend →
  semantic model → bytecode/MIR), потому что они уже разделяют независимо
  проверяемые обязанности.
- **III. Surgical Changes**: Новый исходный код живёт в `zig/`, новые
  тестовые данные — в `tests/`. Текущий `core/`, `wasm/`, `wasm_runtime/` и
  `lsp/` не смешиваются с миграционными изменениями до финального cutover.

**Итог**: нарушений нет. Единственная преднамеренная сложность — собственный
tracing GC: он необходим для сохранения циклических графов значений и не
заменяется корректно refcounting’ом.

## Project Structure

### Documentation (this feature)

```text
specs/010-zig-migration/
├── spec.md
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/
│   ├── cli.md
│   ├── lsp.md
│   └── conformance.md
└── checklists/
    └── requirements.md
```

### Target Source Layout

```text
build.zig                       # единая Zig-сборка после первого среза
build.zig.zon                   # закреплённые зависимости/метаданные
zig/
├── cli/main.zig                # panos: запуск, build --target=wasm, REPL
├── core/
│   ├── source.zig              # Source_File, Span, Diagnostic, UTF-8 helpers
│   ├── lexer.zig
│   ├── ast.zig
│   ├── parser.zig
│   ├── symbols.zig
│   ├── types.zig
│   ├── resolver.zig
│   ├── type_checker.zig
│   ├── module_loader.zig
│   ├── bytecode.zig
│   ├── compiler.zig
│   ├── value.zig
│   ├── gc.zig
│   ├── vm.zig
│   ├── scheduler.zig
│   ├── builtins.zig
│   ├── native/                 # filesystem, process, HTTP, SQL, FFI, compression
│   ├── wasm/                   # MIR, lowering, validation, WASM binary emitter
│   └── lsp_features/           # language-derived LSP computations
├── lsp/main.zig                # JSON-RPC transport and document lifecycle
├── browser/main.zig            # interpreter compiled for browser WASM
└── wasm_runtime/               # runtime linked by generated Panos AOT WASM
tests/
├── conformance/                # manifest + deterministic .ps programs
├── integration/                # native resources, module graph, CLI
├── lsp/                        # JSON-RPC transcripts
└── wasm/                       # browser and wasmtime scenarios
```

**Structure Decision**: `zig/` изолирует новую реализацию от эталона и
исключает частичное смешивание runtime’ов. Внутренние модули следуют уже
существующим границам pipeline, но не обязаны копировать Odin-файлы один к
одному. После cutover каталог может быть переименован отдельной
механической задачей.

## Compatibility Strategy

1. **Сначала зафиксировать наблюдаемое поведение.** Каждый детерминированный
   сценарий получает ID, таргет, вход и нормализованный outcome. Внешние
   сервисы, часы и сеть не попадают в differential golden без контролируемой
   подмены.
2. **Odin — только временный oracle.** До cutover runner исполняет один и
   тот же сценарий старым и новым инструментом, сравнивает stdout, exit
   category, нормализованный результат и диагностические spans. После
   cutover manifest остаётся тестовой базой, а вызов Odin удаляется.
3. **Диагностики сравниваются по контракту.** Обязательны severity, phase,
   path и byte-span; текст фиксируется для уже стабильных русскоязычных
   ошибок. Изменение текста требует классификации в manifest, не
   игнорирования.
4. **Таргет — часть каждого случая.** Native, browser interpreter, AOT JS
   WASM и AOT WASI не считаются взаимозаменяемыми: допустимые builtins и
   результат их запрета проверяются отдельно.
5. **Результат нельзя «договорить потом».** Любое несовпадение блокирует
   следующий gate, пока оно не получит статус регрессии или утверждённого
   исправления эталона.

Полный формат manifest и outcomes описан в
[contracts/conformance.md](./contracts/conformance.md).

## Migration Phases and Gates

### Phase 0 — Baseline and build scaffold

**Deliverables**: `build.zig`, закреплённая Zig `0.16.0`, пустые build steps,
compatibility manifest, runner и классификация текущего тестового набора.

**Work**:

- Описать все 31 текущих core-тестовых файла и 55 fixture’ов как
  deterministic, controlled-external или unsupported-by-target.
- Записать golden outcomes для lexer/parser/semantic/runtime/WASM/LSP
  с неизменяемыми ID.
- Добавить Zig CLI smoke-test и `zig build test` без зависимости от Odin;
  Odin разрешён только в явном шаге `zig build conformance-reference`.
- Зафиксировать toolchain и вендоренные native archives в build graph.

**Exit gate**: чистый checkout выполняет Zig smoke-test; все выбранные
baseline-сценарии имеют утверждённый outcome или явную причину исключения.

### Phase 1 — Source model, lexer and parser

**Deliverables**: Source/Span/Diagnostic model, UTF-8-aware lexer, AST arena,
parser и parser-diagnostic conformance tests.

**Work**:

- Перенести все токены, русские ключевые слова, строки и комментарии.
- Воспроизвести AST для выражений, statements, declarations, type syntax,
  annotations и patterns.
- Собрать parser recovery так, чтобы несколько ошибок одного файла
  накапливались без паники.
- Сравнить токены, AST-формы, spans и diagnostics с Phase 0 golden.

**Exit gate**: 100% conformance-кейсов lexer/parser проходят; fuzz-входы не
вызывают crash, hang или утечку тестового allocator’а.

### Phase 2 — Modules, resolver and type checker

**Deliverables**: Module graph, embedded prelude/stdlib, symbol store,
номинальные типы, generics, match exhaustiveness и target availability.

**Work**:

- Воспроизвести file-based и override-based загрузку модулей для CLI, LSP и
  browser interpreter.
- Перенести export/import, qualified names, closure capture, struct/interface
  implementations, ADT и monomorphization.
- Сделать Target_Profile и Builtin_Availability единым источником правды для
  typechecker, compiler и runtime guards.

**Exit gate**: все semantic/module conformance-кейсы, включая отрицательные,
совпадают с эталоном на каждом применимом таргете.

### Phase 3 — Bytecode, VM, scheduler and tracing heap

**Deliverables**: Bytecode compiler, Value model, non-moving mark-and-sweep
heap, closures, processes/actors, async result queue и VM diagnostics.

**Work**:

- Сохранить типовой выбор opcode до выполнения, frame/call semantics и
  значение хвостовых выражений.
- Реализовать heap object headers, root enumeration (VM frames, globals,
  actor mailboxes, async completions) и explicit collection points.
- Перенести deterministic scheduler и ensure, что native workers не владеют
  GC-объектами напрямую.

**Exit gate**: core runtime, closures, ADT, collections, actors и GC-кейсы
проходят; стрессовые циклические графы не теряют живые объекты и не дают
неограниченного роста при повторяемой нагрузке.

### Phase 4 — Native builtins and external boundaries

**Deliverables**: Native driver adapters и contracts для filesystem, process,
networking/HTTP, HTTP server, compression, SQLite и libffi.

**Work**:

- Сохранить actor-facing async protocol; I/O driver исполняет blocking work
  вне VM и возвращает data-only completion по process ID.
- Собрать/линковать вендоренные `libffi` и `sqlite3` через Zig build, не
  меняя их публичные ABI.
- Реализовать resource lifetime, cleanup и platform guards для opaque native
  values отдельными тестами.

**Exit gate**: controlled native integration-тесты проходят на каждой
поддерживаемой native платформе; запрещённые для WASM builtin’ы отвергаются
и статически, и runtime guard’ом.

### Phase 5 — Browser interpreter and AOT WASM backend

**Deliverables**: Zig browser interpreter, Zig WASM runtime, MIR pipeline,
WASM binary emitter, JS-host contract и WASI test composition.

**Work**:

- Собрать browser interpreter как `wasm32-freestanding` с прежними экспортами
  `panos_source_ptr`, `panos_source_capacity`, `panos_run`, `panos_check`,
  `panos_hover` и `panos_complete`.
- Перенести lowering/validation/stackification/emission Panos AOT WASM без
  подмены этого пути «компиляцией Zig исходников».
- Перенести WASM runtime и проверить generated module в WASI/wasmtime и в
  JS host с DOM/XHR imports.

**Exit gate**: browser smoke и AOT differential suite проходят; generated
WASM не требует Odin runtime или Odin-скомпилированных object files.

### Phase 6 — LSP migration

**Deliverables**: JSON-RPC transport, document lifecycle и все существующие
LSP capabilities поверх Zig semantic model.

**Work**:

- Использовать один frontend/semantic API для CLI и LSP; не дублировать
  parser/resolver/typechecker.
- Воспроизвести override-based graphs для unsaved documents и сохранённые
  documented ограничения multi-document references/rename.
- Выполнить LSP transcripts для всех capability methods.

**Exit gate**: каждый метод из [contracts/lsp.md](./contracts/lsp.md)
проходит положительный и отрицательный transcript; сервер не пишет ничего
кроме protocol output в stdout.

### Phase 7 — Cutover and retirement decision

**Deliverables**: обновлённые build/test/release commands, CI, user docs,
release checklist и решение об архивировании Odin-эталона.

**Work**:

- Переназначить `panos`, `panos-lsp`, browser artifact и AOT runtime на Zig
build graph.
- Удалить Odin из обязательных CI/release dependencies и из documented
quickstart; reference runner оставить только до утверждённой даты удаления.
- Запустить полный conformance matrix и ручные smoke-проверки всех трёх
поставляемых целей.

**Exit gate**: выполнены SC-001…SC-006 из спецификации; чистое окружение без
Odin собирает и тестирует все поставляемые артефакты.

## Complexity Tracking

| Complexity | Why Needed | Simpler Alternative Rejected Because |
|------------|------------|--------------------------------------|
| Собственный non-moving tracing heap | Panos допускает циклические object graphs, closures, actors и ресурсы с shared identity | Refcounting не освобождает циклы и меняет lifetime/семантику |
| Два WASM delivery paths | Browser interpreter выполняет исходник, AOT emitter создаёт самостоятельный Panos WASM | Один Zig→WASM binary не способен заменить генерируемый AOT модуль |
| Compatibility manifest | Odin-тесты не могут напрямую стать Zig unit-тестами | Неформальное ручное сравнение теряет диагностики и platform-specific регрессии |

## Post-Design Constitution Check

- **Think Before Coding**: каждое сложное решение имеет проверяемый exit gate
  и альтернативу в [research.md](./research.md); незакрытых technical
  clarifications нет.
- **Simplicity First**: план сохраняет существующие продуктовые контракты и
  вводит только изоляцию новой реализации и conformance data, необходимые для
  безопасного cutover.
- **Surgical Changes**: до Phase 7 Zig и Odin не смешиваются; текущие
  пользовательские изменения в рабочем дереве не являются частью миграции.
