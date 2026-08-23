# Компилятор, байткод и VM

Эта глава описывает текущую Zig-реализацию Panos. Старое описание Odin
удалено вместе с Odin-пайплайном в рамках миграции `specs/010-zig-migration`.

## Общая схема

У Panos есть два независимых backend-пути после type checking:

```text
исходный текст
  → lexer → parser → resolver → type checker
                                ├─→ AST → bytecode compiler → bytecode VM
                                └─→ AST → MIR lowering → WASM emitter
```

Нативный запуск CLI использует bytecode VM. `panos build --target=wasm`
использует MIR→WASM и не запускает bytecode VM. Поэтому изменение языка,
которое должно работать на обеих целях, обычно требует правки и
`zig/core/compiler.zig`, и `zig/core/mir_lowering.zig`.

Основные файлы:

| Стадия | Реализация |
|---|---|
| Лексер | `zig/core/lexer.zig`, `zig/core/token.zig` |
| AST и parser | `zig/core/ast.zig`, `zig/core/parser.zig` |
| Связывание имён | `zig/core/resolver.zig` |
| Типы и type checking | `zig/core/types.zig`, `zig/core/type_checker.zig` |
| Bytecode | `zig/core/bytecode.zig`, `zig/core/compiler.zig` |
| Исполнение | `zig/core/vm.zig`, `zig/core/value.zig`, `zig/core/gc.zig` |
| MIR/AOT | `zig/core/mir.zig`, `zig/core/mir_lowering.zig`, `zig/core/wasm_emit.zig` |

## Типизированная программа

`resolver.zig` превращает имена в стабильные `SymbolId`, связывает импорты,
методы, generic-инстанциации и builtin-модули. `type_checker.zig` затем
заполняет `CheckResult` типами узлов, проверяет возвращаемые значения,
интерфейсы, ADT, коллекции, `Опция`/`Результат` и управление потоком.

Обе backend-стадии получают уже разрешённую и типизированную программу.
Они не должны заново выводить типы или разрешать имена. Это важная граница
для будущей формализации в Lean: первым формальным представлением лучше
сделать typed AST, а не текстовый язык с лексером.

## Bytecode compiler

`compiler.zig` строит `bytecode.Program` и набор `bytecode.Function`.
Функция содержит инструкции, константы, размер frame, признак возвращаемого
значения и метаданные, необходимые для вызовов. `bytecode.Opcode` включает:

- арифметику, сравнение и логические операции;
- локальные переменные и переходы;
- вызовы, замыкания и интерфейсную диспетчеризацию;
- массивы, соответствия, структуры, туплы и ADT;
- процессы, сообщения, сигналы и отмену;
- файловые, сетевые, HTTP, SQLite и DOM builtin-инструкции;
- FFI и операции со строками.

Компилятор сначала регистрирует функции, чтобы разрешить forward references,
затем компилирует тела и лямбды. Вызовы builtin выбираются по уже известному
типу и символу, поэтому VM не обязана повторять всю логику type checker.

`отложить` реализован как структурный cleanup stack компилятора. Cleanup
исполняется в обратном порядке при выходе из блока, функции, цикла,
`возврат`, `прервать`, `продолжить` и успешном разворачивании `?`. Для
возврата значения compiler сохраняет результат на стеке, исполняет cleanup,
затем возвращает значение.

## Bytecode VM

`Vm.run()` (`zig/core/vm.zig`) создаёт корневой процесс и выполняет его через
планировщик. `step()` исполняет одну инструкцию текущего frame и возвращает
`StepOutcome`:

- `completed` — инструкция завершилась;
- `suspended` — процесс ждёт mailbox, signal или async-результат;
- `none` — обычное продолжение выполнения.

Frame хранит функцию, instruction pointer, локальные слоты и состояние
замыкания. Значения представлены `value.Value`; heap-объекты принадлежат
`gc.Heap`. VM владеет heap и создаёт GC-managed значения только на основном
потоке.

Асинхронные builtin-операции используют плоские payload-структуры и worker
threads. Worker не обращается к `Value` и `gc.Heap`; результат возвращается
в основной поток и только там превращается в Panos-значение. Если операция
ещё не завершена, инструкция остаётся на том же `ip` и процесс будет
передиспетчеризован позже.

Ошибки делятся на диагностические ошибки до запуска и runtime errors. `паника`
и runtime error останавливают текущий запуск; VM сейчас не выполняет
универсальное stack unwinding, поэтому `отложить` не является обработчиком
паники.

## MIR и WASM AOT

`mir_lowering.zig` понижает типизированный AST в MIR с явными `ValueId`,
блоками и control-flow. MIR валидируется перед emission; среди проверок есть
валидность блоков/значений и single-use-инварианты, необходимые текущему
представлению MIR.

`wasm_emit.zig` превращает MIR в самостоятельный WASM-модуль. Этот путь
имеет собственные runtime-модули (`zig/wasm_runtime/`) и не использует
байткодную VM. `zig build aot` проверяет реальные WASM-объекты через
wasmtime, а `zig build browser` проверяет freestanding browser-сборку.

## Точки изменения

Изменение синтаксиса проходит вертикальным срезом:

1. token/lexer;
2. AST/parser;
3. resolver;
4. type checker;
5. bytecode compiler;
6. MIR lowering, если функция доступна в AOT;
7. VM или WASM emitter/runtime;
8. `zig/core/runner.zig` и conformance fixture.

Новый opcode требует обработки в `bytecode.Opcode`, emission в
`compiler.zig` и dispatch в `Vm.step()`. Для AOT предпочтительнее добавлять
MIR-инструкцию или существующий MIR-паттерн, а не пытаться вызвать bytecode
VM из WASM.

## Основа для Lean 4

Lean-модель следует строить вокруг typed AST и отдельной семантики bytecode:

```text
Typed AST → source semantics
Typed AST → bytecode → bytecode semantics
```

Первая полезная теорема — preservation/progress для чистого подмножества
(числа, boolean, `если`, локальные переменные, функции, ADT). Затем можно
доказать compiler simulation для bytecode. FFI, сеть, async, GC, процессы,
DOM и WASM следует подключать как отдельные effect-модели с явно указанными
предположениями.

До полного доказательства полезно экспортировать из Zig typed AST,
bytecode и детерминированные VM-трассы в тестовый формат. Lean-интерпретатор
сможет сравнивать эти артефакты с эталонной семантикой, а `zig build
conformance` — запускать те же программы на реальной VM и AOT backend.

## Проверки

Перед изменением compiler/VM/AOT должны проходить:

```sh
zig build test
zig build conformance
zig build lsp
zig build browser
```

Для изменений WASM дополнительно используется `zig build aot`; для
интеграций с реальными ресурсами — `zig build integration`.
