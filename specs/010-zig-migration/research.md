# Research: решения для переноса Panos на Zig

## 1. Toolchain and build graph

**Decision**: Использовать и закрепить Zig `0.16.0`; все основные команды
делать build steps в `build.zig`. Не использовать Zig master в CI или
релизном пути.

**Rationale**: В рабочем окружении уже установлен `0.16.0`, а официальный
релиз доступен как стабильная версия. Zig build system предоставляет
проектные build steps и target options, поэтому native/LSP/WASM-артефакты
могут собираться из одного graph без Odin.

**Alternatives considered**:

- Zig master — отклонён: API std/build меняется, что создаёт не связанную с
  Panos churn-работу во время долгого переноса.
- Сохранить Justfile как первичный build driver — отклонён: он привязан к
  Odin; thin compatibility wrapper допустим только после Zig build steps.

**Sources**: [Zig 0.16.0 release](https://ziglang.org/download/0.16.0/),
[Zig Build System](https://ziglang.org/learn/build-system/).

## 2. Ownership and garbage collection

**Decision**: Реализовать для Panos отдельный non-moving mark-and-sweep heap
со stable object handles; Zig allocator управляет памятью самого heap, но не
заменяет Panos GC.

**Rationale**: Zig не имеет автоматического runtime memory management и
требует явного allocator’а. Panos значения образуют циклы (структуры,
массивы, map, closures, interfaces и actor mailboxes), поэтому refcounting
без cycle collector изменил бы lifetime и дал утечки. Non-moving объекты
сохраняют pointer identity для `Value` и безопасны для VM frames.

**Alternatives considered**:

- Один ArenaAllocator на весь запуск — отклонён для VM: не освобождает
  временные runtime object graphs в долго живущем LSP/browser instance.
- Refcounting — отклонён: не решает cycles.
- Полная аллокация на Zig stack — отклонена: runtime values и closures
  переживают stack frames.

**Sources**: [Zig memory and allocators](https://ziglang.org/documentation/0.16.0/#Memory),
[Zig standard library](https://ziglang.org/documentation/0.16.0/std/).

## 3. Source, diagnostics and deterministic compatibility

**Decision**: Все frontend-подсистемы используют один `Source_File`/`Span` и
накопительный список `Diagnostic`; conformance сравнивает нормализованные
наблюдаемые outcomes, а не внутренние Odin структуры.

**Rationale**: CLI, LSP и browser уже используют один semantic pipeline, но
разные способы поставки исходника (filesystem, overrides, static buffer).
Единый source model не позволит LSP выдавать другие positions, чем CLI.
Нормализация path/temp-name/stack details сохраняет meaningful differences и
не делает golden хрупкими к окружению.

**Alternatives considered**:

- Port existing Odin unit-tests строка-в-строку — отклонён: они вызывают
  Odin-private structures, а не публичный contract.
- Сравнивать только exit code — отклонено: теряются значения, stdout,
  diagnostics и target errors.

## 4. Frontend and semantic boundaries

**Decision**: Переносить lexer → parser/AST → module graph/resolver → type
checker как независимые Zig-модули с общими IDs; monomorphization остаётся
после typechecking и до executable lowering.

**Rationale**: Эта последовательность уже является границей тестирования и
необходима одновременно bytecode VM, AOT backend и LSP. Перестановка стадий
во время миграции добавит новую семантику вместо переноса.

**Alternatives considered**:

- Прямо интерпретировать AST и отложить bytecode — отклонено: изменит
  existing opcode/static-type behaviour и удвоит работу перед AOT.
- Генерировать Zig source из Panos — отклонено: не сохраняет dynamic VM,
  actors, diagnostics и независимый WASM emitter.

## 5. Asynchronous native I/O

**Decision**: Сохранить actor-facing async contract: VM ставит operation по
process ID, native adapter выполняет blocking work вне VM и возвращает
data-only completion, которую VM materializes на собственном потоке.

**Rationale**: Это уже защищает однопоточный доступ к Panos heap и даёт
одинаковую observable scheduler semantics. Смена механизма workers не должна
попасть в язык или API builtin’ов.

**Alternatives considered**:

- Блокировать VM на filesystem/network calls — отклонено: ломает actors и
  HTTP server concurrency.
- Передавать `Value`/GC-pointers worker’ам — отклонено: создаёт races и
  неявные roots.

## 6. Native C boundaries

**Decision**: SQLite и libffi остаются explicit native build dependencies с
нынешними вендоренными архивами и C ABI; Zig code объявляет минимальные
bindings и изолирует их в native adapter layer.

**Rationale**: Пользовательский FFI требует динамического вызова различных
сигнатур, для чего нужен libffi. SQLite уже поставляется как platform archive.
Их замена новой библиотекой одновременно с языковым переносом не добавляет
пользовательской ценности и расширяет риск.

**Alternatives considered**:

- Убрать FFI/SQL до «последующих версий» — отклонено FR-003 и FR-006.
- Вызовы C напрямую из semantic/VM кода — отклонено: platform and resource
  policy должна быть проверяемой в одном adapter boundary.

## 7. Two WebAssembly products

**Decision**: Поддерживать два самостоятельных WASM-продукта: (1) browser
interpreter, скомпилированный Zig для `wasm32-freestanding`; (2) Panos AOT
emitter, генерирующий WASM module и линкующий Zig WASM runtime для JS/WASI.

**Rationale**: Browser playground должен анализировать и исполнять source в
инстансе интерпретатора. AOT режим должен выдавать WebAssembly программы
Panos, а не один общий interpreter binary. Zig поддерживает freestanding
WASM и выделение памяти для этого окружения; WASI остаётся отдельной
test/runtime целью.

**Alternatives considered**:

- Только browser interpreter — отклонён: теряется `panos build
  --target=wasm`.
- Только AOT — отклонён: не обслуживает interactive check/hover/completion.
- Использовать один host ABI для JS и WASI — отклонён: DOM/XHR imports
имеют принципиально другой contract.

**Sources**: [Zig WebAssembly documentation](https://ziglang.org/documentation/0.16.0/#WebAssembly),
[wasm32-wasi support](https://ziglang.org/learn/platform-support/wasm32-wasi/).

## 8. Target availability and runtime guards

**Decision**: Target_Profile и Builtin_Availability становятся shared semantic
data. Typechecker проверяет недоступность до lowering; bytecode VM и native
resource methods повторно проверяют её на runtime boundary; AOT emitter
получает только доступные imports.

**Rationale**: Текущий проект уже установил этот принцип для `DOM::*`,
`сеть::http_запрос_sync` и native-only builtin’ов. Одна таблица исключает
drift между static error, VM panic и generated WASM import list.

**Alternatives considered**:

- Проверки в каждом builtin — отклонено: списки неизбежно расходятся.
- Только typecheck guard — отклонено: ошибочный/синтетический bytecode мог
  бы вызвать запрещённую операцию.

## 9. LSP boundary

**Decision**: LSP сохраняет JSON-RPC/stdin-stdout contract и вызывает тот же
Zig frontend/semantic model, что CLI. Protocol models определяются в Zig, а
не переносятся из generated Odin file.

**Rationale**: Раздвоенный parser/typechecker уже был бы источником
несовпадающих diagnostics. Generated Odin protocol является деталью текущего
toolchain, не публичным API Panos.

**Alternatives considered**:

- Оставить Odin LSP как отдельную поставку — отклонено FR-011.
- Реализовать только diagnostics/hover — отклонено FR-008.

## 10. Parallel research and integration ownership

**Decision**: На implementation planning использовать независимые аудиты
frontend, VM/WASM и LSP/test inventory; один владелец интеграции принимает
семантические решения и утверждает conformance changes.

**Rationale**: Подсистемы читаются параллельно, но изменения в language
semantics и compatibility manifest требуют одного источника решения.

**Alternatives considered**:

- Независимые параллельные порты без общего oracle — отклонены: приведут к
несовместимым моделям `Span`, `Type` и `Value`.
