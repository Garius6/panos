# Компилятор и VM

Компилятор и VM документируются ОДНОЙ главой — типичное изменение (новый
оператор, новый opcode) трогает оба файла как одну логическую операцию,
раздельные главы создали бы ложное впечатление, что они независимы (см.
`plan.md` → Structure Decision).

## Что

**`Opcode :: enum u8`** (`core/compiler.odin:291`) — 49 вариантов, ключевые
группы: арифметика (`Add`/`Subtract`/`Multiply`/`Divide`/`Int_Divide`/`Modulo`),
сравнение (`Less`/`Greater`/`Equal`/`Negate`), локальные переменные
(`Get_Local`/`Set_Local`), управление потоком (`Jump`/`Jump_If_False`/`Call`/
`Return`), структуры данных (`Build_Aggregate`/`Get_Property`/`Set_Property`/
`Build_Array`/`Build_Map`/`Get_Index`/`Set_Index`), интерфейсы
(`Cast_Interface`/`Invoke_Interface`), ADT (`Match_Tag`/`Get_Variant_Field`/
`Build_Variant`/`Match_Fail`), акторы (`Spawn`/`Receive`/`Receive_Signal`),
неблокирующий I/O (`Call_Builtin_Async`/`Invoke_Collection_Async`/
`Await_Async` — см. ниже), FFI (`Call_Foreign`), замыкания
(`Build_Closure`/`Get_Captured`), битовые операции (`BitAnd`/`BitOr`/
`BitXor`/`BitNot`/`ShiftLeft`/`ShiftRight`).

**`Compiled_Function`** — `name`, `instructions: [dynamic]u8` (байткод),
`constants: [dynamic]Value` (пул констант функции), `frame_size`,
`returns_value`.

**`compile_program`** (`core/compiler.odin:540`) —
`(res: ^Resolver_Ctx, tc: ^Type_Ctx, program: ^Program, registry: ...) -> map[string]^Compiled_Function`.
Два прохода: Pass 1 (hoisting — пустые заглушки `Compiled_Function` для
всех функций/методов, даёт forward-references), Pass 2 (компиляция тел).
Между проходами вызывается `monomorphize_program` (см.
[дженерики](./generics-and-monomorphization.md)) — инстанциации bounded
generic-функций должны попасть в registry ДО того, как обычная компиляция
дойдёт до их call site'ов.

**`GC_Header`** (`core/gc.odin:46`) — `{marked: bool}`. Комментарий в
начале `compiler.odin`: ВСЕ heap-managed варианты `Value` (кроме `f64`/
`bool`/`^Compiled_Function`) встраивают `GC_Header` ПЕРВЫМ полем —
`Aggregate_Value`, `Array_Value`, `Map_Value`, `Error_Value`,
`Option_Value`, `Result_Value`, `Interface_Value`, `Variant_Value`,
`File_Value`, `Socket_Value`, `Process_Value`, `Closure_Value`,
`Pointer_Value`.

**`execute`** (`core/vm.odin:1542`) — `(vm: ^VM) -> Exec_Result`, главный
цикл VM: пока есть кадры (`vm.frames`), берёт текущий `CallFrame`, читает
байт по `frame.ip`, кастит в `Opcode`, `#partial switch opcode` — 40+
кейсов, каждый читает операнды из `instructions[frame.ip±N]`, работает с
`vm.stack`, продвигает `frame.ip`.

**`CallFrame`** — `function: ^Compiled_Function`, `ip: int`,
`frame_pointer: int` (индекс в `vm.stack`, откуда начинаются локали этого
кадра), `closure: ^Closure_Value` (не-nil только для вызовов замыкания).

**Неблокирующий I/O** (`core/vm_async.odin`, `core/vm_async_io_native.odin`/
`_wasm.odin`, `core/gc.odin`): планировщик (`run_scheduler`, ниже) — строго
single-OS-thread, кооперативный round-robin по `vm.processes`. Раньше ЛЮБОЙ
блокирующий вызов (`сеть.http_запрос`, `фс.прочитать`, `.получить_строку()`
и т.п.) исполнялся синхронно ПРЯМО внутри `execute()` — останавливал
планировщик целиком, ни один другой процесс не выполнялся, пока I/O не
завершится. Сейчас такие вызовы компилируются в пару опкодов вместо одного
`Call_Builtin`/`Invoke_Collection`:

- `Call_Builtin_Async`/`Invoke_Collection_Async` — та же операнд-форма, что
  у синхронных версий (имя-константа + `arg_count`, у `Invoke_Collection_*`
  ещё receiver со стека), но НЕ исполняют вызов сами — кладут задачу в
  `VM.async_pool` (`core:thread.Pool`, 4 потока, `new_vm`) через
  `submit_async_io`/`submit_async_io_method` (`vm_async_io_native.odin`) и
  СРАЗУ идут дальше (submit не блокирует).
- `Await_Async` — suspend/resume механика, зеркалящая `Receive_Signal`, но
  над ОТДЕЛЬНОЙ очередью `Process_Value.async_results` (не `mailbox`) —
  если очередь пуста, `return .Suspended` без сдвига `ip` (следующий вызов
  `execute()` для этого процесса перезаходит в ТУ ЖЕ инструкцию); отдельная
  очередь нужна, чтобы результат СВОЕГО async-вызова не перепутался с
  обычным сообщением, пришедшим, пока процесс ждал (тот же мотив, что у
  `signals`/`Receive_Signal` для DOWN-сигналов).

Компилятор решает, для КАКИХ builtin'ов/методов эмитить async-пару —
`is_async_builtin_name`/`is_async_stream_method` (`compiler.odin`,
`case .Builtin:`/`case .Method_Collection:`). Для методов выбор идёт по
СТАТИЧЕСКОМУ типу receiver'а (`ctx.tc.node_types[prop_expr.object]` ==
`TY_FILE`/`TY_CONNECTION`), а не только по имени метода — `"получить"`
одновременно метод `Option`/`Result`/`Array`/`Map` (чистый get-with-default,
диспетчится рантайм-типом в `invoke_collection_method`) и `Socket_Value`
(блокирующий сетевой read) — без проверки типа компилятор не отличил бы их.

Воркер физически касается ТОЛЬКО простых Odin-типов (`string`/`int`/
`Maybe`) — никогда не вызывает `gc_new*`/строит `Value` — GC (`core/gc.odin`)
не имеет НИ ОДНОЙ блокировки, предполагает эксклюзивный однопоточный
доступ. Единственное исключение — стриминговые методы над уже открытым
хендлом: чтение (`File_Value.прочитать`/`.прочитать_строку`,
`Socket_Value.получить`/`.получить_строку`) — воркер физически читает
`&file.reader`/`&sock.reader`, поле GC-managed объекта; запись
(`File_Value.записать`, `Socket_Value.отправить`) — воркер пишет через сам
`.handle`/`.socket` (`os.write`/`net.send_tcp`), reader не трогает. Оба
случая безопасны ТОЛЬКО благодаря `gc_pin`/`gc_unpin` (`core/gc.odin`, см.
[память и сборщик мусора](./memory-and-gc.md)), которые держат объект
искусственным GC-корнем весь полёт, плюс `in_flight`/`close_requested` на
самом объекте (`file_value_native.odin`) — ОДИН общий флаг на чтение И
запись (не отдельные read/write-флаги): блокирует ЛЮБУЮ вторую
конкурентную операцию (в т.ч. запись во время чужого чтения и наоборот) и
откладывает `.закрыть()` до завершения воркера.

`deliver_async_result`/`drain_async_completions` (`core/vm.odin`) — на
ГЛАВНОМ потоке, в момент дренирования канала `VM.async_completions`
(`core:sync/chan`), строят `Value` из результата и кладут в
`process.async_results` того процесса, что инициировал вызов (по
`target_id`, НЕ указателю — процесс мог завершиться/быть убит, пока I/O
было в полёте; тот же silent-drop, что у `отправить()` на мёртвый процесс,
ресурсы всё равно освобождаются). `run_scheduler`'s дедлок-guard различает
настоящий дедлок и "все ждут I/O в полёте" через
`thread.pool_num_outstanding(&vm.async_pool)` (атомарный счётчик пула).

## Зачем

Компиляция в байткод вместо прямого обхода AST — типы уже полностью
проверены к моменту кодогенерации, значит выбор конкретного opcode
(например `Int_Divide` vs `Divide`) можно сделать ОДИН РАЗ на этапе
компиляции, а не на каждом вызове во время исполнения. `GC_Header`
встроен в каждый heap-управляемый вариант `Value`, чтобы у сборщика мусора
был единый способ найти mark-бит для ЛЮБОГО heap-объекта без отдельной
параллельной таблицы метаданных, индексированной по адресу (см.
[память и сборщик мусора](./memory-and-gc.md)).

## Почему так, а не иначе

**`Int_Divide` — отдельный от `Divide` opcode** (`vm.odin:1624`,
комментарий): `Целое`/`Целое` — усечение к нулю (как в C/Rust/Go, НЕ floor
как в Python); `Число`/`Число` — обычное деление. Оба типа на рантайме —
`f64` (у `Целое` нет отдельного `Value`-варианта, см.
`Type_Kind.Integer`) — VM физически не может отличить их в момент
исполнения, поэтому выбор opcode — статический, делает его КОМПИЛЯТОР по
`ctx.tc.node_types[e.left] == TY_INT` (`compiler.odin:1061`), не VM по
значению.

**Битовые операторы — только для `Целое`**, проверено ЕЩЁ тайпчекером
(`infer_binary_expr`/`infer_unary_expr`, см. [тайпчекер](./type-checker.md)) —
VM конвертирует `f64`→`i64`, делает битовую операцию, конвертирует обратно
(рантайм-представление всё равно `f64`, отдельного целочисленного
`Value`-варианта нет).

**`.And`/`.Or` не предкомпилируют оба операнда заранее** (`compiler.odin:1043-1046`,
комментарий): правый операнд может не выполниться (short-circuit) — для
левоассоциативной цепочки `и`/`или` (где `e.left` сам `Binary_Expr`)
предкомпиляция дала бы `O(2^n)` инструкций плюс мусор на стеке VM. Вместо
этого `.And`/`.Or` компилируются СПЕЦИАЛЬНО: `compile_expr(e.left)`,
`Jump_If_False`, `compile_expr(e.right)`, с патчем прыжков.

## Точки входа для типичной правки

Для нового бинарного оператора (например ещё одного арифметического) —
трогать ВСЕ три места сразу, они образуют одну логическую операцию (общий
[рецепт](./recipes/new-binary-operator.md)):

| Шаг | Файл/функция |
|---|---|
| 1. Объявить opcode | `Opcode :: enum u8` (`compiler.odin:291`) |
| 2. Эмиссия на стороне компилятора | `compile_expr`, кейс `^Binary_Expr` (`compiler.odin:973`), внутренний `#partial switch e.op` (строки 1019+) — `emit_opcode(ctx, .НовыйOpcode)`; если выбор opcode зависит от статического типа (как `Int_Divide`/`Divide`) — проверка `ctx.tc.node_types[e.left]` |
| 3. Обработчик на стороне VM | `execute`, `#partial switch opcode` (`vm.odin:1542`+) — новый `case .НовыйOpcode:`, снять операнды с `vm.stack` через `pop`, положить результат через `append` |

| Другое изменение | Файл/функция |
|---|---|
| Новый heap-управляемый `Value`-вариант | ОБЯЗАТЕЛЬНО первым полем `GC_Header` (`gc.odin:46`) — иначе сборщик мусора не найдёт mark-бит, см. [память и сборщик мусора](./memory-and-gc.md) |
| Новый builtin (`ввод_вывод.печать` и т.п.) | `Call_Builtin`-кейс в `execute` (не новый opcode на каждый builtin — один универсальный `Call_Builtin` с именем-константой) |
| Сделать builtin/метод неблокирующим для планировщика | добавить имя в `is_async_builtin_name`/`is_async_stream_method` (`compiler.odin`) + `case` в `submit_async_io`/`submit_async_io_method` (`vm_async_io_native.odin`, воркер строит ТОЛЬКО простые типы) + `case` в `deliver_async_result` (`vm.odin`, `Value` строится ЗДЕСЬ, на главном потоке) — новый суспенд-примитив не нужен, `Await_Async` уже общий |
| Изменить формат FFI-вызова | `Call_Foreign`-кейс, `core/vm_ffi_native.odin` |
