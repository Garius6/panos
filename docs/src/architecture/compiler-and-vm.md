# Компилятор и VM

Компилятор и VM документируются ОДНОЙ главой — типичное изменение (новый
оператор, новый opcode) трогает оба файла как одну логическую операцию,
раздельные главы создали бы ложное впечатление, что они независимы (см.
`plan.md` → Structure Decision).

## Что

**`Opcode :: enum u8`** (`core/compiler.odin:284`) — 46 вариантов, ключевые
группы: арифметика (`Add`/`Subtract`/`Multiply`/`Divide`/`Int_Divide`/`Modulo`),
сравнение (`Less`/`Greater`/`Equal`/`Negate`), локальные переменные
(`Get_Local`/`Set_Local`), управление потоком (`Jump`/`Jump_If_False`/`Call`/
`Return`), структуры данных (`Build_Aggregate`/`Get_Property`/`Set_Property`/
`Build_Array`/`Build_Map`/`Get_Index`/`Set_Index`), интерфейсы
(`Cast_Interface`/`Invoke_Interface`), ADT (`Match_Tag`/`Get_Variant_Field`/
`Build_Variant`/`Match_Fail`), акторы (`Spawn`/`Receive`/`Receive_Signal`),
FFI (`Call_Foreign`), замыкания (`Build_Closure`/`Get_Captured`), битовые
операции (`BitAnd`/`BitOr`/`BitXor`/`BitNot`/`ShiftLeft`/`ShiftRight`).

**`Compiled_Function`** — `name`, `instructions: [dynamic]u8` (байткод),
`constants: [dynamic]Value` (пул констант функции), `frame_size`,
`returns_value`.

**`compile_program`** (`core/compiler.odin:474`) —
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
`File_Value`, `Connection_Value`, `Process_Value`, `Closure_Value`,
`Pointer_Value`.

**`execute`** (`core/vm.odin:1485`) — `(vm: ^VM) -> Exec_Result`, главный
цикл VM: пока есть кадры (`vm.frames`), берёт текущий `CallFrame`, читает
байт по `frame.ip`, кастит в `Opcode`, `#partial switch opcode` — 40+
кейсов, каждый читает операнды из `instructions[frame.ip±N]`, работает с
`vm.stack`, продвигает `frame.ip`.

**`CallFrame`** — `function: ^Compiled_Function`, `ip: int`,
`frame_pointer: int` (индекс в `vm.stack`, откуда начинаются локали этого
кадра), `closure: ^Closure_Value` (не-nil только для вызовов замыкания).

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

**`Int_Divide` — отдельный от `Divide` opcode** (`vm.odin:1567`,
комментарий): `Целое`/`Целое` — усечение к нулю (как в C/Rust/Go, НЕ floor
как в Python); `Число`/`Число` — обычное деление. Оба типа на рантайме —
`f64` (у `Целое` нет отдельного `Value`-варианта, см.
`Type_Kind.Integer`) — VM физически не может отличить их в момент
исполнения, поэтому выбор opcode — статический, делает его КОМПИЛЯТОР по
`ctx.tc.node_types[e.left] == TY_INT` (`compiler.odin:995`), не VM по
значению.

**Битовые операторы — только для `Целое`**, проверено ЕЩЁ тайпчекером
(`infer_binary_expr`/`infer_unary_expr`, см. [тайпчекер](./type-checker.md)) —
VM конвертирует `f64`→`i64`, делает битовую операцию, конвертирует обратно
(рантайм-представление всё равно `f64`, отдельного целочисленного
`Value`-варианта нет).

**`.And`/`.Or` не предкомпилируют оба операнда заранее** (`compiler.odin:977-983`,
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
| 1. Объявить opcode | `Opcode :: enum u8` (`compiler.odin:284`) |
| 2. Эмиссия на стороне компилятора | `compile_expr`, кейс `^Binary_Expr` (`compiler.odin:907`), внутренний `#partial switch e.op` (строки 984+) — `emit_opcode(ctx, .НовыйOpcode)`; если выбор opcode зависит от статического типа (как `Int_Divide`/`Divide`) — проверка `ctx.tc.node_types[e.left]` |
| 3. Обработчик на стороне VM | `execute`, `#partial switch opcode` (`vm.odin:1485`+) — новый `case .НовыйOpcode:`, снять операнды с `vm.stack` через `pop`, положить результат через `append` |

| Другое изменение | Файл/функция |
|---|---|
| Новый heap-управляемый `Value`-вариант | ОБЯЗАТЕЛЬНО первым полем `GC_Header` (`gc.odin:46`) — иначе сборщик мусора не найдёт mark-бит, см. [память и сборщик мусора](./memory-and-gc.md) |
| Новый builtin (`ввод_вывод.печать` и т.п.) | `Call_Builtin`-кейс в `execute` (не новый opcode на каждый builtin — один универсальный `Call_Builtin` с именем-константой) |
| Изменить формат FFI-вызова | `Call_Foreign`-кейс, `core/vm_ffi_native.odin` |
