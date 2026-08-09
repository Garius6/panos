# Отчёт о состоянии Zig-миграции Panos

**Дата:** 2026-08-05
**Статус:** самостоятельный Zig-путь уже выполняет существенный однофайловый
поднабор Panos и поставляет работающие CLI/browser/LSP артефакты, но ещё не
заменяет Odin-реализацию целиком.

## Граница работы

Zig-реализация находится в `zig/` и собирается из `build.zig`. Она не вызывает
Odin-бинарники и не смешивает состояния runtime'ов. Изменения в существующих
`core/*.odin`, `main.odin` и документации остаются пользовательскими и не
включались в Zig-коммиты.

Следующий большой этап — расширить уже работающий минимальный module graph до
номинальных типов, generic'ов, методов и общей prelude/stdlib-семантики.

## Реализовано

### Общий pipeline и runtime

- Zig build graph создаёт CLI `panos`, LSP `panos-lsp`, browser WASM и
  scaffolds JS/WASI AOT runtime.
- Портированы UTF-8 source spans, lexer, parser с recovery, AST, resolver,
  type checker, bytecode compiler, VM и собственный tracing heap.
- Поддерживается проверенный однофайловый поднабор языка: функции и лямбды,
  замыкания, структуры, интерфейсы, generic-функции и типы, ADT/`выбор`,
  `Опция`/`Результат`, коллекции, циклы, `if`-выражения, процессы/акторы и
  runtime diagnostics.
- Общий API `zig/core/runner.zig` используется CLI, browser и LSP, поэтому
  parser/resolver/type checker не дублируются по delivery path.
- `zig build run -- test.ps` успешно выполняет основной демонстрационный
  файл на момент этого отчёта.

### Модули: загрузка, linking и исполнение

- `zig/core/module_loader.zig` строит локальный граф импортов, нормализует
  пути, собирает exports, сортирует зависимости и диагностирует циклы и
  отсутствующие файлы.
- `zig/core/module_linker.zig` передаёт каталог экспортов в
  `resolver.resolveWithImports`; квалифицированные имена импортов
  семантически распознаются.
- `zig/core/module_compiler.zig` компилирует graph в topological порядке в
  один `bytecode.Program`. Он сохраняет origin импортированного символа,
  подставляет реальный `FunctionId` экспортированной функции и literal
  constant, а затем запускает `старт` entry-модуля.
- Первый исполнимый срез покрывает квалифицированные вызовы экспортированных
  функций и literal constants со структурными сигнатурами (`Число`,
  `Строка`, `Булево`, `Пусто`, кортежи, функции, массивы, maps, процессы и
  указатели). Проверка аргументов проходит в importing module.
- Экспортированный nominal type получает graph-wide identity по origin
  декларации. Значение можно создать/вернуть в исходном модуле и передать в
  другую его экспортированную функцию как opaque value; одноимённые типы
  разных модулей остаются несовместимы.
- Для обычной экспортированной структуры поддержаны qualified annotations
  `модуль.Тип`, constructor `модуль.Тип(...)` и чтение полей. Methods,
  enum variants, generic parameters и interface implementations через module
  boundary пока не поддержаны. Эти случаи остаются контролируемой границей,
  пока отдельные symbol/type stores не получат полную shared semantic model.
- Cross-module methods для НЕ-generic owner-типа теперь работают:
  same-file `реализация Тип ... конец` (без "для", без generic owner)
  на экспортированной структуре/перечислении вызывается из другого модуля
  как обычный `.метод()` — как через прямой constructor-литерал
  (`точки.Точка(41)`), так и через значение, возвращённое импортированной
  функцией (`точки.создать(41)`). Механизм: `module_loader.zig` собирает
  `MethodExport` (owner declaration + method declaration) для импл-блоков
  на экспортированном owner'е; `module_linker.zig` прикладывает их к
  соответствующему `.type`-экспорту; `resolver.zig` минтит для каждого
  такой метод НОВЫЙ локальный Symbol_Id в SymbolStore импортёра
  (`ImportedMethodBinding`) — метод не именован в scope (диспатчится
  структурно на значении, не по квалифицированному имени, поэтому не
  использует module_members/alias-механизм обычных импортов);
  `module_compiler.zig` ре-хостит сигнатуру метода и уже скомпилированный
  `FunctionId` через тот же `ImportContext`, что и обычные функции;
  `type_checker.zig`'s `importSignaturePass` регистрирует их как обычный
  `MethodDefinition` — `compiler.zig` не потребовал ни одного изменения,
  т.к. `function_ids` уже origin-agnostic map (Symbol_Id → FunctionId
  общий на весь `bytecode.Program`). Оказалось (проверено `zig test`), что
  interface-impl методы (`реализация Сравниваемое для Точка`) — это ТОЖЕ
  обычные inherent-методы (`defineMethodSignature`/`self.result.methods`
  в type_checker.zig не различает plain/interface impl), так что
  изначальный skip интерфейсных impl'ов в `collectMethods` был лишним —
  убран, `.сравнить()` как ОБЫЧНЫЙ метод-вызов на импортированном типе
  заработал сразу же, без доп. кода.
- Cross-module enum variants для НЕ-generic owner-типа тоже работают:
  конструирование (`цвета.Цвет.Красный()`) и `выбор` по значению
  импортированного enum'а (включая variant с полем-данными,
  `итог.Итог.Готово(41)` → `выбор r \n Готово(x) -> ... конец`) — обе
  формы проверены отдельными regression-тестами. Конструирование/матчинг
  enum-вариантов в `compiler.zig` целиком string-based
  (`enumVariantName` строит `"Owner.Variant"` из ИМЕНИ owner-символа, не
  из его numeric identity) — поэтому здесь, в отличие от методов,
  вообще не нужен FunctionId/re-hosting сигнатуры: `module_loader.zig`
  собирает `VariantExport` (owner declaration + имя варианта) для
  экспортированного `перечисление`; `module_linker.zig` прикладывает их
  к `.type`-экспорту; `resolver.zig` минтит для каждого варианта новый
  `Symbol_Id{kind: .enum_variant, owner_type: <локальный owner symbol>}`
  и регистрирует в `Resolution.enum_variants` — ровно то же место, что
  `registerEnumDeclaration` уже использует для локальных enum'ов, так
  `findEnumVariant` не отличает импортированный вариант от локального;
  для variant'ов с полями `module_compiler.zig` дополнительно прокидывает
  `target_checked.enum_definitions.get(target_symbol).variants` НАПРЯМУЮ
  (без копирования — тот `EnumDefinition` живёт столько же, сколько весь
  graph compile) в `type_checker.ImportedNominal.enum_variants`, и
  `importSignaturePass` строит `EnumDefinition` для локального owner'а,
  ре-хостя только сами field-типы через `copyImportedType`.
- Generic owner-типы (struct ИЛИ enum) через границу модуля с конкретным
  type-аргументом тоже работают: `короб.Коробка(Число) = короб.Коробка(42)`
  (generic-структура), `короб.Ящик(Число) = короб.Ящик.Есть(42)`
  (generic-перечисление, включая `выбор` по нему), и методы на обоих
  (`к.развернуть(0)` с `T`-параметром/возвратом) — все 4 комбинации
  покрыты отдельными regression-тестами. Механизм: `copyImportedType`
  получил 4-й параметр `generic_remap: ?*const AutoHashMap(TypeId, TypeId)`
  (`null` для не-generic импортов — сохраняет прежнее поведение, теперь
  явно `error.UnsupportedImportedType` только когда remap реально нужен,
  но не передан); `importSignaturePass` строит ОДИН remap НА КАЖДЫЙ
  generic owner (минтит свежий `types.genericParameter(...)` на каждый
  исходный generic-параметр owner'а — `next_generic_parameter` совместно
  используется с обычным single-file generic-выводом, чтобы не
  столкнуться id) и переиспользует ЭТОТ ЖЕ remap для полей структуры,
  полей вариантов enum'а И сигнатур методов НА этом owner'е — иначе `T` в
  поле структуры и `T` в её импортированном методе получили бы РАЗНЫЕ
  локальные generic-параметры, ломая унификацию. `module_compiler.zig`
  прокидывает owner'ские generic-параметры одним полем
  `ImportedNominal.generic_parameters` независимо от struct/enum
  (`generic_nominal_fields.get(...).parameters` для структуры,
  `enum_definitions.get(...).parameters` для enum'а — оба одного типа
  `[]const GenericParameter`), так что `importSignaturePass` не различает
  struct/enum при построении remap'а, только при выборе, КУДА положить
  результат (`generic_nominal_fields` vs `enum_definitions`).
- Interface vtables через границу модуля тоже работают — оба сценария
  проверены: (1) прямой interface-typed cast (`пер x: Сравниваемое = a`,
  затем `x.сравнить(b)`) и (2) generic-bound dispatch
  (`макс[T: Сравниваемое](a, b)`, вызванный со значениями импортированного
  типа) — для структуры, чей `реализация Сравниваемое для Точка` живёт в
  ЗАВИСИМОСТИ, не в импортёре. Обошлось БЕЗ единой строчки в
  `compiler.zig`/`vm.zig`: раз методы интерфейс-импла уже импортируются
  как обычные inherent-методы (см. выше), а `Cast_Interface`/vtable в
  compiler.zig резолвится через `struct_type.methods` (те же
  `self.result.methods`) — всё, что реально не хватало, это сама запись
  `InterfaceImplementation{interface, arguments, target, methods}` в
  `self.result.interface_implementations` ИМПОРТЁРА (её проверяет
  generic-bound constraint check и direct-cast validity check). Новый
  `module_loader.ImplExport{module, owner_declaration, interface_name}`
  собирается в том же проходе, что и `MethodExport` (по тем же impl-блокам,
  просто ещё и когда `interface_name != null`); дальше НЕ нужен ни
  `module_linker.zig`, ни новые Symbol_Id в `resolver.zig` — интерфейс
  резолвится ПО ИМЕНИ в СВОЁМ scope импортёра (`Сравниваемое` — prelude,
  у каждого файла свой локальный символ, копировать чужой id бессмысленно),
  а методы уже смэтчены по имени с уже-импортированными
  `self.result.methods`. Вся работа — в
  `module_compiler.zig`'s `ImportContext.collect` (получил `graph`
  четвёртым параметром: ищет `target_checked.interface_implementations`
  по `.target == target_symbol` и совпадению имени интерфейса) и
  `type_checker.ImportedImpl`/`importSignaturePass` (ре-хостит
  `.arguments` через тот же `copyImportedType`+owner remap, что и
  поля/методы, матчит `.methods` по имени против уже построенных
  `self.result.methods`, пишет итоговую `InterfaceImplementation`).
- Побочно найден и исправлен ЕЩЁ один реальный баг того же паттерна:
  конструктор generic-структуры (`тип X = случай .nominal` в
  `inferCall`, строка с `constructor_type = ...`) строил результирующий
  тип через `types.nominal(...)` (identity=0 по умолчанию) вместо
  `self.nominalType(...)` (который проверяет
  `imported_nominal_identities` и сохраняет opaque cross-module
  identity) — тот же класс бага, что и в `substituteGeneric` ниже, тем
  же способом обнаруженный (реальный `zig test`, не чтением кода):
  `короб.Коробка(41)` типизировался с identity=0, а объявленная
  аннотация `короб.Коробка(Число)` — с identity=1, давая ложный
  "значение переменной не совпадает с аннотацией" на КАЖДОМ
  конструкторе generic-структуры импортированного типа. Однострочный фикс
  (`self.result.types.nominal` → `self.nominalType`), не затрагивает
  не-generic конструкторы (у них отдельная ветка, `callee_type` уже
  корректен).
- Побочно найден и исправлен реальный баг: `type_checker.zig`'s
  `substituteGeneric` для `.nominal`-веток пересобирал тип через
  `types.nominal(...)` (identity=0 по умолчанию), теряя opaque
  cross-module identity любого nominal-типа, проходящего через
  generic-подстановку — раньше не проявлялся, т.к. ни один существующий
  путь не гонял identity-несущий (`identity != 0`) nominal через
  `substituteGeneric` до появления cross-module методов (сигнатура метода
  ВСЕГДА проходит через `substituteGeneric`, даже без реальных
  generic-параметров). Заменено на `nominalWithIdentity(nominal.symbol,
  nominal.identity, ...)`.
- Qualified impl target (`реализация Интерфейс для чужой_модуль.Тип`) и
  qualified interface-side (`реализация чужой_модуль.Интерфейс для Тип`)
  были распарсены (`ast.zig`'s `target_module`/`interface_module`,
  `parser.zig` их заполняет), но ПОЛНОСТЬЮ игнорировались в
  `type_checker.zig` — `signaturePass` резолвило владельца ТОЛЬКО через
  `findTypeSymbol(implementation.target_type)` (голое имя),
  `defineInterfaceImplementation` — ТОЛЬКО через
  `findTypeSymbol(interface_name)`, оба игнорируя соответствующее поле
  `_module`. И то и другое уже давно существует как
  `findQualifiedTypeSymbol` (используется для qualified
  type-аннотаций) — просто не был подключён к этим двум местам. Теперь
  оба используют `findQualifiedTypeSymbol(module_name, name)`, когда
  соответствующее поле не `null`.
- В процессе проверки qualified impl target нашёлся ЕЩЁ один реальный
  identity-баг — на этот раз не "какой конструктор", а ПОРЯДОК проходов:
  `imported_nominal_identities` заполнялась внутри `importSignaturePass`,
  который бежит ПОСЛЕ `signaturePass` — а `signaturePass` уже резолвит
  qualified-аннотации (например, receiver-параметр импла, `это:
  точки.Точка`) через `nominalType`, которая ЧИТАЕТ
  `imported_nominal_identities`. Значит на момент, когда `signaturePass`
  резолвил qualified-аннотацию, идентичность ЕЩЁ не была записана —
  аннотация получала identity=0, а любое РЕАЛЬНОЕ значение того же
  импортированного типа (посчитанное позже, уже после
  `importSignaturePass`) — identity=1, давая ложный "получатель метода
  имеет неверный тип" на КАЖДОМ qualified impl target внутри одного и
  того же файла. Не проявлялся раньше, т.к. до qualified impl target
  ничего не резолвило qualified-nominal-аннотацию именно во время
  `signaturePass` (обычные функции с qualified-параметром типа тоже
  резолвятся в `signaturePass`, но их баг незаметен: и параметр, и
  аргумент вызова получают identity=0 СОГЛАСОВАННО, т.к. вызывающая
  функция обычно резолвится в той же самой ранней фазе — конфликт
  всплывает только когда ОДНО И ТО ЖЕ значение сравнивается между
  результатом `signaturePass`-фазы (identity=0) и результатом
  ПОЗЖЕ-резолвленного выражения (identity=1), что как раз и происходит
  внутри тела импл-метода). Фикс: новый `importIdentityPass` — регистрирует
  ТОЛЬКО `imported_nominal_identities` (без полей/методов/enum variants),
  вызывается ДО `signaturePass`; сам `importSignaturePass` (поля, generic
  remap, методы, enum variants, impls) остаётся ПОСЛЕ `signaturePass`, как
  и раньше — эти данные `signaturePass` не использует.
- ЗАКРЫТО (был отдельно записан как пробел, решён в этой же сессии):
  импорт САМОГО ОПРЕДЕЛЕНИЯ интерфейса (не только его реализации) из
  третьего модуля. `ImportedNominal` получил `interface_methods:
  ?[]const InterfaceMethod` (та же "ссылка на чужую структуру данных
  напрямую" техника, что `enum_variants`/`generic_parameters` — источник
  живёт весь graph compile, копий не нужно); `module_compiler.zig`
  дополнительно проверяет `target_checked.interface_definitions.get(
  target_symbol)` для `.type`-экспортов (интерфейс тоже `.type`-kind
  export, т.к. `module_loader.zig`'s `collectExports` уже трактует
  `.interface_decl` так же, как struct/enum). Найденный ПРИ ЭТОМ РЕАЛЬНЫЙ
  БАГ (третий той же природы, но другого класса — не identity, а порядок
  проходов): `interface_definitions` для импортированного интерфейса
  строилась внутри `importSignaturePass`, который бежит ПОСЛЕ
  `signaturePass` — а `signaturePass` уже пытается валидировать импл
  (`defineInterfaceImplementation` → `self.result.interface_definitions.
  get(interface_symbol)`) ДЛЯ ТЕКУЩЕГО файла, если тот содержит
  qualified impl target на чужой интерфейс. Фикс: `importIdentityPass`
  (уже существовавший для `imported_nominal_identities`, см. ниже)
  расширен — строит generic-remap И `interface_definitions` для
  импортированных интерфейсов ДО `signaturePass`; сами remap-карты
  (`owner_remaps`/`owner_parameters_by_symbol`) стали параметрами,
  общими между `importIdentityPass` и `importSignaturePass` (раньше были
  локальными переменными ВНУТРИ `importSignaturePass`, из-за чего их
  нельзя было переиспользовать в более раннем проходе). Проверено
  отдельным regression-тестом ("module compiler resolves a qualified
  interface-side impl target across a third module") — БЕЗ Self-типизированного
  параметра интерфейса (см. следующий пункт).
- Найден пре-существующий, НЕ cross-module-специфичный пробел (не
  чинился — вне рамок этой сессии): пользовательские (не prelude)
  интерфейсы НЕ поддерживают Self-параметр в сигнатуре метода.
  `interfaceMethodMatches` (`type_checker.zig`) хардкодит "Self"-логику
  ТОЛЬКО для `Сравниваемое` (`isComparableInterface` special case,
  строка ~871) — любой пользовательский интерфейс с методом вида
  `сравнить(другое: МойИнтерфейс) -> Число` в принципе не может быть
  корректно реализован НИКАКИМ конкретным типом (сравнение параметра
  делается буквально, без подстановки Self → реализующий тип), ни в
  одном файле, ни через границу модуля — обнаружено ТОЛЬКО реальным
  прогоном (`zig test`), не чтением кода.
- Отдельно найдено и исправлено: `zig/core/module_loader.zig`,
  `module_linker.zig`, `module_compiler.zig` и `zig/core/runner.zig`
  не были подключены ни к одному test step в `build.zig` — их
  `test {...}` блоки (352 теста, включая уже существовавшие
  module-compiler/module-loader regression-тесты) никогда не
  выполнялись `zig build test`. Добавлены `module_loader_unit_tests`/
  `module_linker_unit_tests`/`module_compiler_unit_tests`/
  `runner_unit_tests` в `build.zig` (тот же паттерн, что у
  `vm_unit_tests` — `root_source_file` указывает прямо на файл). После
  фикса `zig build test` показывает 785/785 вместо прежних 369/369
  (число продолжает расти по мере добавления regression-тестов в этой же
  сессии).
- CLI использует graph compiler и выполняет локальные multi-file программы.
  Browser/LSP остаются на single-source API и по-прежнему не выполняют
  импорты без filesystem/document graph.

### Prelude embedding — реально заменён для основного пути

`zig/core/prelude.zig` содержит настоящий `PRELUDE_SOURCE` (Опция/Результат/7
интерфейсов, портировано из Odin's `core/prelude.odin`) — проверен
САМОСТОЯТЕЛЬНО (lex→parse→resolve→typecheck→compile как обычная программа,
реальным `zig test`, а не чтением) и компилируется чисто. Два места
потребовали правки под более строгий Zig-чекер: `функ опция(это: Результат)
-> Опция` и `функ ошибка_опция(это: Результат) -> Опция` — Odin допускал
bare-generic-имя в annotation-позиции (неявно вывод аргумента), Zig-чекер
требует явный `Опция(T)`/`Опция(E)` в самой аннотации возврата (иначе
"неверное количество параметров типа перечисления" — найдено `zig test`, не
чтением).

Механизм внедрения (graph-based):

- `module_loader.Graph.appendPreludeModule(source)` — добавляет prelude как
  ОБЫЧНЫЙ модуль graph'а, но ПОСЛЕ всех уже загруженных реальных модулей
  (получает file_id ПОСЛЕ них — существующие diagnostics-тесты, ожидающие
  `file_id == 0` у entry-файла, не ломаются) и ВСТАВЛЯЕТСЯ ПЕРВЫМ в `order`
  (компилируется раньше всех, кто от него implicit-зависит). Переиспользует
  `collectExports`/`collectMethods` буква в букву — те же function/impl/
  variant-сборщики, что для настоящего файла.
- `module_linker.ImportScope.initWithPrelude` — даёт КАЖДОМУ ДРУГОМУ модулю
  (кроме самой прелюдии) implicit import-edge на неё, без alias, помечен
  `.unqualified = true`.
- `resolver.zig`'s новый `predeclareUnqualifiedImport` — сливает exports
  прелюдии НАПРЯМУЮ в bare scope (`Опция(T)`, не `alias.Опция`), вместо
  module-wrapper обычного импорта — переиспользует ТОЧНО ТОТ ЖЕ механизм
  минтинга method/enum-variant символов, что и qualified-путь, только
  результат идёт в `self.scopes.declare(...)` напрямую, а не в
  `members.values`.
- `resolver.resolveModule`'s новый флаг `skip_prelude_hardcode`. ПЕРВАЯ
  версия этого флага была `true` ТОЛЬКО когда резолвится сам prelude-модуль
  — этого оказалось НЕДОСТАТОЧНО: когда реальная prelude в графе есть,
  КАЖДЫЙ ДРУГОЙ модуль (не только сама прелюдия) получает Опция/Результат
  через unqualified-merge, но параллельно ВСЁ ЕЩЁ получал их же через
  хардкод в `installBuiltins` — "символ 'Опция' уже объявлен" для
  ПОЛЬЗОВАТЕЛЬСКОГО файла (найдено `zig test`, не чтением, при первой
  попытке реально прогнать runner.zig через graph). Исправлено: флаг —
  `prelude_module != null` (есть ли ВООБЩЕ prelude-модуль в графе),
  проверяется в `module_compiler.compileGraph` для КАЖДОГО обрабатываемого
  модуля, не только для самой прелюдии.

### Prelude embedding — swap для однофайлового пути (CLI/browser/LSP) сделан

`runner.zig` (общая точка входа `analyzeSourceForTarget`/
`runSourceWithVerboseForTarget`, используемая CLI/browser/LSP для программы
БЕЗ явного `импорт` — подавляющее большинство реального использования)
теперь строит `module_loader.Graph` с пользовательским файлом как модулем 0
и добавленной прелюдией, компилирует через НОВЫЙ
`module_compiler.compileGraphForTarget` (протягивает `target.TargetProfile`
через graph-путь — раньше `compileGraph` вообще не поддерживал target,
понадобилось для browser-reject тестов). `SourceAnalysis` (используется LSP
для hover/completion/diagnostics) теперь читает `.tree()`/`.resolution()`/
`.checkedResult()` из `graph.modules[0]`/`compiled.modules[0]` — модуль
пользователя ГАРАНТИРОВАННО индекс 0 (загружается `graph.load()` ДО
`appendPreludeModule`). `reportUnsupportedImports` (реальный `импорт` пока не
поддержан в single-file режиме — ЭТО решение НЕ менялось) сохранён как
отдельная, ПРЕДВАРИТЕЛЬНАЯ lex+parse проверка ДО построения graph — иначе
настоящий `импорт` попытался бы загрузиться через graph reader (у которого
есть только один файл) и дал бы другое сообщение об ошибке ("не удалось
загрузить модуль"), а не специфичное "выполнение импортов ещё не
поддержано".

Проверено, что через НОВЫЙ путь реально ИСПОЛНЯЮТСЯ (не только тайпчекаются)
настоящие скомпилированные методы прелюдии, не хардкод-заглушка:
`Опция.Есть(41).получить(0) + Опция.Нет().получить(1) == 42` — regression-тест
в `runner.zig`, ПЛЮС живой `zig build run` на реальном `.ps`-файле с
`.получить()`/`.результат_или()` (`40 + 2 + 40 == 82`, верно).

Побочно найден и исправлен РЕАЛЬНЫЙ баг: `SingleFileReader.read` был не
`pub` — компилятор ловит межфайловый вызов через `anytype`-параметр
(`graph.load(reader, ...)` инстанцирует generic-вызов `reader.read(...)` в
`module_loader.zig`, а Zig требует `pub` для методов, вызываемых из ДРУГОГО
файла даже через duck-typed `anytype`).

`type_checker.zig`'s `preludePass` и `compiler.zig`'s
`compilePreludeEnumMethod`/`inferPreludeEnumMethod` (оба всё ещё
безусловные, по имени) остаются в коде, но БЕЗВРЕДНЫ на новом пути:
`preludePass` бежит ДО нового `importIdentityPass`, который БЕЗУСЛОВНО
перезаписывает его `enum_definitions`/`interface_definitions` для
Опция/Результат корректными cross-module-импортированными версиями (map
`.put()` — последняя запись побеждает); `compilePreludeEnumMethod`'s
диспатч по имени метода никогда фактически не срабатывает для вызовов на
graph-пути, т.к. они резолвятся через обычный inherent-method dispatch,
построенный для cross-module методов (T033), а не через хардкод-ветку
компилятора. НЕ убраны (dead code, не баг) — единый источник истины пока не
достигнут буквально (хардкод физически ещё в файле), но НИКАКОЙ реальный
код через него больше не проходит на graph-пути.

Единственное намеренно НЕ тронутое: ~300 тестов в `vm.zig`/
`type_checker.zig`/`compiler.zig`/`resolver.zig`, вызывающие
`lexer.tokenize`+`resolver.resolve()`/`type_checker.check()` НАПРЯМУЮ (не
через `runner.zig`) — они по-прежнему используют хардкод
(`resolveWithImports`/`resolve()` по умолчанию `skip_prelude_hardcode=
false`, без изменений). Это НЕ пробел, а сознательная граница: хардкод и
новый механизм взаимно исключающие ПО ПУТИ ВЫЗОВА и не конфликтуют друг с
другом — миграция этих тестов на `runner.zig` (чтобы буквально удалить
хардкод из файла) — опциональная уборка на будущее, не требуется для
корректности.

### Target policy и runtime guards

- `zig/core/target.zig` содержит единый каталог доступности builtin'ов для
  `native`, browser bytecode VM, JS AOT WASM и WASI.
- Первый настоящий вертикальный срез — `фс.есть(Строка)`: resolver
  регистрирует builtin-module, type checker проверяет сигнатуру и target,
  compiler emits `file_exists`, native VM использует `Io.Dir.access`.
- Второй срез, `фс.удалить(Строка)` (`Io.Dir.deleteFile`, `.file_delete`
  opcode), добавлен в ТОТ ЖЕ builtin-module — подтвердил, что паттерн
  масштабируется на несколько функций без изменений в `target.zig`
  (там уже была ОБЩАЯ проверка по префиксу `"фс::"`, не поимённый список,
  так что новое имя automatически покрыто static/runtime guard'ом).
  Изменения нужны только в: `resolver.zig` (добавить имя в
  `installBuiltinModule("фс", &.{...})`), `type_checker.zig` (новый
  `isBuiltinModule(symbol, "фс", "удалить")` блок), `compiler.zig`
  (новая ветка в `compileFilesystemBuiltin`), `bytecode.zig` (новый
  `Opcode`/`Instruction` вариант), `vm.zig` (новая `fileDelete` — тот же
  `comptime builtin.target.os.tag == .freestanding` panic-branch, что и
  `fileExists`, единый файл для native/wasm, в отличие от Odin, где это
  два отдельных файла `vm_io_native.odin`/`vm_io_wasm.odin`).
- Третий и четвёртый срез: `фс.прочитать(Строка) -> Результат(Строка, Ошибка)`
  и `фс.записать(Строка, Строка) -> Результат(Число, Ошибка)` (`Io.Dir.
  readFileAlloc`/`.writeFile`) — первые FALLIBLE native builtin'ы,
  подтвердили, что ошибка native-операции корректно заворачивается в тот же
  `Результат`/`Ошибка`, что использует panos-код (`Результат.Неудача(
  Ошибка("фс", @errorName(err)))`), а не отдельный, специальный error-канал.
  Новый общий helper в `vm.zig`: `pushSuccessResult`/`pushErrorResult`
  строят `Результат.Успех(...)`/`Результат.Неудача(Ошибка(...))` как
  обычные tagged-aggregate (та же техника, что `queueSignal`'s
  `Опция.Есть`/`Опция.Нет`) — переиспользуются любым будущим fallible
  builtin'ом без повторения этой логики. `type_checker.zig` получил
  `resultOfString` helper — строит `Результат(T, Ошибка)` через
  `findTypeSymbol("Результат")` + `nominalType` (не голый
  `.types.nominal`), чтобы identity корректно подхватывалась и с
  hardcode-путём, и с реальным prelude-путём (T032) без дублирования кода
  на каждый builtin.
  Побочно найден и исправлен реальный баг: `compileFilesystemBuiltin` имел
  early-guard `if (call.arguments.len != 1) return false;` В САМОМ НАЧАЛЕ
  функции — блокировал `фс.записать` (2 аргумента) от того, чтобы вообще
  дойти до диспетчеризации по имени. Найдено `zig test`, не чтением: после
  добавления `.записать`-ветки тест падал с "вызвано значение, не
  являющееся функцией" — guard был написан для единственного
  на тот момент 1-арного builtin'а (`фс.есть`) и никогда не пересматривался
  при добавлении `удалить` (тоже 1-арный, баг не проявлялся).
- Browser runner передаёт `.browser_interpreter`, поэтому все четыре среза
  получают static diagnostic до компиляции. VM повторяет проверку перед
  host access и сообщает policy-defined runtime panic для вручную
  созданного bytecode.
- Таблица и русскоязычные static/runtime сообщения, native adapter,
  browser rejection и VM runtime boundary покрыты тестами (все четыре
  функции, включая живой `zig build run` round-trip записать→прочитать).
- Остальные `фс::*` (директории), `DOM::*`, сетевые, SQL и
  FFI вызовы пока не зарегистрированы/не портированы; для них guard нельзя
  считать реализованным.

### Browser interpreter

- `zig/browser/main.zig` собирается в `wasm32-freestanding` и экспортирует
  ABI буферов исходника/результата.
- Реализованы `panos_run`, `panos_check`, `panos_hover` и `panos_complete`.
- Browser использует тот же `runner`: run/check, диагностики, UTF-16 hover
  и методы/поля completion проходят через Zig frontend.
- `docs/src/assets/interactive.js` совместим и со старым Odin WASM, и с
  новым Zig result-buffer ABI.

### LSP

`zig/lsp/main.zig` реализует стандартный JSON-RPC transport через stdin/stdout
и `Content-Length`; stdout содержит только protocol messages.

Поддержаны и заявлены в `initialize`:

- lifecycle: `initialize`, `shutdown`, `exit`, `didOpen`, full-text
  `didChange`, `didClose`;
- diagnostics с UTF-16 line/character диапазонами;
- `textDocument/hover` и completion после `.`;
- `textDocument/foldingRange` и `textDocument/documentSymbol`;
- `textDocument/definition`, `textDocument/references` и
  `textDocument/documentHighlight` для текущего документа;
- `textDocument/signatureHelp` для обычных вызовов функций.

Новые LSP-срезы были записаны отдельными коммитами:

| Commit | Содержание |
| --- | --- |
| `51c5b99` | transport, document lifecycle, diagnostics, hover, completion |
| `16b82d7` | structural outline и folding ranges |
| `f1dee2c` | definition, references и document highlights |
| `2244b97` | signature help |

## Проверки, выполненные перед отчётом

Успешно выполнены:

```sh
zig build test --summary none
zig build conformance --summary none
zig build run -- test.ps
zig build lsp --summary none
```

Также выполнен реальный запуск CLI временного двухфайлового graph: импорт
`мат.сложить(мат.ОТВЕТ, 2)` вывел `42`.

Кроме unit-тестов, LSP запускался как отдельный процесс. Проверены настоящие
`Content-Length` кадры и JSON-RPC ответы для diagnostics, hover, completion,
outline, folding ranges, definition, references, highlights и signature help.

Не запускались Odin-тесты и не проверялись пользовательские изменения в
Odin-файлах: они не относятся к Zig-срезам и не должны быть перезаписаны.

## Оставшаяся работа

### Критичный P1: расширение module graph

1. ~~Раскрыть imported nominal types в methods и enum variants~~ — ГОТОВО
   (methods + enum variants, non-generic и generic owner, см. выше).
2. ~~Расширить `ImportContext` на generic definitions, methods и interface
   vtables~~ — ГОТОВО: generic owner-типы (struct/enum) без сохранения
   несовместимых копий generic parameter IDs (единый remap на owner) И
   interface implementations (прямой cast И generic-bound dispatch), см.
   выше. Известные узкие места: qualified interface-side
   (`реализация модуль.Интерфейс для ...`) через границу — не проверено;
   match-exhaustiveness конкретно на импортированном ADT — не проверено.
3. Подтвердить hidden/private exports, missing export, import cycle и runtime
   diagnostics в dependency; цепочка из трёх файлов уже покрыта e2e-тестом.
4. Спроектировать unsaved document graph поверх этой модели для browser/LSP.

### Builtin'ы и target guards

- Портировать native adapters: filesystem/process/compression/syntax,
  networking/HTTP server/client, SQLite и FFI.
- Ввести обычный builtin dispatch в compiler/VM с именем и
  `TargetProfile`; таблица `target.zig` проверяется до lowering и повторно
  на runtime boundary.
- Отдельно обработать opaque-resource methods: они не являются обычными
  builtin calls и требуют guard в соответствующем адаптере.
- Только после этого переносить DOM/sync HTTP и AOT WASM import surface.

### AOT и browser delivery

- Browser interpreter уже рабочий для однофайлового bytecode path, но
  отдельный AOT pipeline (MIR, lowering, validation, stackification,
  binary emission) ещё не портирован.
- JS и WASI runtime сейчас scaffolds; нужны generated-WASM и wasmtime/browser
  integration tests без Odin artifacts.
- CLI `panos build --target=wasm` пока не реализует договорённый AOT contract.

### Оставшиеся LSP capabilities

Контракт `contracts/lsp.md` ещё требует:

- cross-document `definition`/`references` и unsaved override graph;
- `workspace/symbol`, `semanticTokens/full`, `codeLens`, `selectionRange`;
- полные transcript tests, включая invalid-input responses всех методов.

Текущие references/highlights намеренно ограничены одним сохранённым в LSP
документом. Это честная граница до общего module graph и index-а открытых
документов.

`prepareRename`/`rename` — ГОТОВО (`zig/lsp/main.zig`, `renameProvider:
{prepareProvider: true}` в capabilities). Переиспользуют тот же
`tree.findExpressionAt`+`expr_symbols`-путь, что `definition`/
`references`/`documentHighlight` — реализация ограничена ТЕКУЩИМ
документом, той же границей, что и они. `rename` собирает
`WorkspaceEdit` из двух источников: `expr_symbols` (все употребления
символа — как у `references`) плюс, отдельно, место объявления через
НОВУЮ `preciseDeclarationSpan` (не переиспользует существующую
`definitionSpan` напрямую — та возвращает "затычку" на весь `Span`
объявления, когда точного under-name-only span нет).

Найдена и исправлена в ревью реальная проблема: для функций/констант
(`decl_symbols`) есть точный `name_span` — их объявление безопасно
попадает в edit-список. Для ЛОКАЛЬНЫХ `пер`/`конст` внутри функции
такого точного under-name span просто не существует в AST
(`ast.zig`'s `Stmt.let` хранит `span` на ВСЁ выражение объявления,
не только на имя) — включить сюда `entry.span`-заглушку означало бы
заменить `пер a: Число = 1` целиком на новое имя, ломая синтаксис.
`preciseDeclarationSpan` поэтому возвращает `null` для локальных
объявлений, и rename для них намеренно переименовывает ТОЛЬКО реальные
употребления, не саму строку `пер ...` — задокументированное
ограничение, не полная фича, но безопасное (не портит исходник) и
покрыто тестом на shadowing (`пер a` во внешнем/вложенном `если`,
внешнее употребление переименовывается, внутреннее — нет, объявление —
не в edit-списке).

Живой прогон через реальный `Content-Length`-фрейминг (`zig build lsp`
+ настоящий JSON-RPC по stdin, не только in-process `server.handle`
юнит-тесты) подтвердил корректный `WorkspaceEdit` на функции (и
объявление, и употребление, оба со сдвигом на правильные UTF-16
позиции).

### Поддержка и cutover

- Обновить `README.md` и архитектурные документы Zig-командами и boundary
  model.
- Добавить CI matrix для `zig build test`, conformance, browser и AOT tests.
- Сверить/расширить conformance corpus runtime/module/native/browser/aot/lsp.
- Не переключать release/Pages/Justfile на Zig до закрытия module execution,
  native boundary и AOT exit gates.

## Рекомендуемый порядок продолжения

1. Расширить существующий graph compiler на nominal types, methods, generics
   и prelude/stdlib без копирования идентичностей типов.
3. Добавить первые native builtin adapters вместе с static + runtime target
   guards из `target.zig`.
4. На общей semantic model завершить cross-document LSP и rename/reference
   операции.
5. Портировать MIR/AOT/runtime и добавить target integration matrix.
6. Завершить docs/CI/conformance и только затем планировать cutover Odin.

## Состояние рабочей копии

В рабочей копии присутствуют изменённые, staged deleted и untracked Odin/docs
файлы, принадлежащие пользователю. Они не входят в перечисленные Zig-коммиты;
перед дальнейшими Git-операциями нужно продолжать коммитить только явные пути
из `zig/`, `build.zig` и относящихся Zig-тестов.

## Продолжение T037: четыре директориальных среза фс

Расширил уже готовый паттерн (`фс.есть`/`фс.удалить`/`фс.прочитать`/
`фс.записать`) на `фс.это_директория`, `фс.создать_директорию`,
`фс.список_директории` и `фс.удалить_директорию` — тот же вертикальный срез
(resolver export → type_checker сигнатура → compiler опкод → vm.zig runtime)
на каждый:

- `resolver.zig` `installBuiltinModule("фс", ...)` — четыре новых имени
  экспорта.
- `type_checker.zig` `inferCall` — `это_директория` возвращает `Булево`
  (как `есть`); `создать_директорию`/`удалить_директорию` возвращают
  `Результат(Число, Ошибка)` (как `записать`); `список_директории`
  возвращает `Результат(Массив(Строка), Ошибка)` — первый случай,
  подтверждающий, что `resultOfString`-хелпер (misleadingly named,
  реально `Результат(T, Ошибка)` для любого `T`) обобщается и на
  `Массив`-обёрнутый payload, не только на скаляры.
- `bytecode.zig`/`compiler.zig` — четыре новых опкода
  (`dir_is_dir`/`dir_create`/`dir_list`/`dir_delete`), диспетчеризуются в
  `compileFilesystemBuiltin` по имени свойства и количеству аргументов,
  тем же способом, что и уже существующие четыре.
- `vm.zig` — `dirIsDir`/`dirCreate`/`dirList`/`dirDelete`. Используют
  `std.Io.Dir` (0.16 IO-интерфейс, тот же `std.Io.Threaded` per-call, что
  и у файловых срезов): `statFile(...).kind == .directory` для
  `это_директория`; `createDirPath` для `создать_директорию` (уже
  идемпотентен в самой стандартной библиотеке — "успех, если путь уже
  директория" — тот же контракт, что у Odin-версии, без ручной
  нормализации ошибки `.Exist`); `openDir(.{.iterate=true})` +
  `Iterator.next` для `список_директории`, копируя `entry.name` в
  GC-строку на каждой итерации (буфер `Iterator`-а инвалидируется
  следующим `next`); `deleteDir` с фоллбеком на `deleteTree` для
  `удалить_директорию` — тот же двухшаговый паттерн (файл/пустая
  директория первым, рекурсивно только если не получилось), что у Odin
  `remove`/`remove_all`. `фс::удалить` (единичный файл, БЕЗ рекурсивного
  фоллбека) не тронут — разграничение "удалить"/"удалить_директорию" уже
  словесно закреплено в Odin-версии и переносится без изменений.
- `target.zig` не менялся — префиксная проверка `фс::` уже покрывает
  любое новое имя автоматически (подтверждено новыми browser-rejection
  тестами).
- Новые e2e-тесты в `runner.zig` (та же форма, что у уже существующих
  фс-тестов — `runSource`/`checkSourceForTarget`, НЕ ручной запуск CLI):
  создание+запись+это_директория+список_директории одним сценарием,
  это_директория на обычном файле (false), удаление директории и
  проверка её реального исчезновения с диска, плюс четыре
  browser-target-rejects теста. `zig build test`/`conformance`/`lsp` —
  все зелёные (788 тестов, было 787 минус один временно красный, пока не
  нашёл, что метод массива называется `получить(индекс, запасное)`, а не
  `получить_или`).

Не начато: `фс.открыть` (нужен `File_Value`-подобный тип ресурса в Zig
VM, которого пока нет вообще — потоковый файл, не одноразовая
операция) и остальные `фс::*` вне scope T037 (там их и не было).


## Файловый дескриптор: фс.открыть + Файл.прочитать/прочитать_строку/записать/закрыть

Портировал последний недостающий кусок T037 — `фс.открыть`, первый opaque-
resource тип на Zig-стороне (до этого только скалярные/`Результат`-обёрнутые
builtin'ы). Полный вертикальный срез:

- **Тип `Файл`** — непараметрический nominal-тип, устанавливается ПРЯМО из
  `resolver.zig` (`installBuiltinType`, symmetric `installBuiltinModule`
  выше), а не через встроенную прелюдию — как и у Odin (`TY_FILE`,
  `core/type_cheker.odin`) это компилятором зашитое имя, у которого никогда
  не будет реального `тип Файл = ...` объявления в исходнике.
- **type_checker.zig** — `фс.открыть(путь)` возвращает `Результат(Файл,
  Ошибка)`; методы `.прочитать`/`.прочитать_строку`/`.записать`/`.закрыть`
  диспетчеризуются в `inferPreludeEnumMethod` новой веткой `owner.name ==
  "Файл"`, ТЕМ ЖЕ способом, что уже существующие ветки `Опция`/`Результат`
  (эта функция уже была общим местом для method-диспетчеризации по имени
  nominal-владельца, не только для двух прелюдийных перечислений).
- **compiler.zig** — `compilePreludeEnumMethod` получила симметричную ветку
  `owner.name == "Файл"`, эмитящую четыре новых опкода
  (`file_handle_read`/`file_handle_read_line`/`file_handle_write`/
  `file_handle_close`); `фс.открыть` сам эмитится через уже существующий
  `compileFilesystemBuiltin` (новый опкод `file_open`).
- **value.zig/gc.zig** — новый heap-тип `FileHandle` (`header`, `path`,
  `is_open`, `offset`), новый вариант `Value.file`/`Object.file`,
  `Heap.createFile`.

### Реальный OS-дескриптор НЕ хранится — ключевое отличие от Odin

Первая попытка держать живой `std.Io.File` в `FileHandle` и читать через
позиционный `std.Io.File.Reader`/`.writePositionalAll` (естественный
Zig-эквивалент Odin'овского `bufio.Reader` над открытым хендлом) СЛОМАЛА
`zig build browser` (wasm32-freestanding):

```
std/Io/Threaded.zig:2064: error: struct 'posix.system...' has no member named 'getrandom'
const use_dev_urandom = @TypeOf(posix.system.getrandom) == void and native_os == .linux;
referenced by: RandomFile <- Io.Threaded
```

Подтверждено экспериментально (`git stash` откатывал ИМЕННО эти правки —
`zig build browser` тут же снова собирался), что просто вызывать
`std.Io.Threaded.init(...)` (как уже делают `фс.прочитать`/`фс.записать`
и остальные однократные `фс.*`) безопасно для freestanding-таргета — ломает
именно комбинация с `File.reader()`/`File.writer()`/positional read-write:
эти функции создают `std.Io.File.Reader`/`.Writer`, чья инициализация
эagerly требует полностью резолвнутый `RandomFile` (nested тип с полем
`use_dev_urandom`, вычисляемым на уровне контейнера) — а его объявление
ссылается на `posix.system.getrandom`, которого нет в posix-заглушке для
`wasm32-freestanding`. Простые целые-файловые операции (`Dir.access`,
`Dir.readFileAlloc`, `Dir.writeFile`, `Dir.deleteFile`) этот путь не
затрагивают вообще — поэтому уже существующие `фс.*` срезы всегда
собирались нормально.

Решение — `FileHandle` хранит ТОЛЬКО `path` (duped) и логический курсор
`offset: usize`; каждый метод заново открывает файл ПО ПУТИ через уже
доказанно wasm-безопасные whole-file helper'ы:

- `.прочитать()`/`.прочитать_строку()` — `readFileAlloc` всего файла,
  срез от `offset` (для строки — до первого `\n`, с обрезкой хвостового `\r`, тем же способом, что Odin's `strings.trim_right(raw_line, "\r\n")`), `offset` продвигается на длину съеденного куска.
- `.записать(текст)` — тоже `readFileAlloc` целиком, затем "позиционная
  перезапись" в памяти (аналог `pwrite` на `offset`: префикс без
  изменений, `текст` поверх, хвост после `offset+len(текст)` сохраняется
  если он длиннее) и `writeFile` всего результата обратно. Обычный паттерн
  "открыл → несколько `.записать()` подряд → закрыл" (текст всегда
  дописывается ровно с той позиции, где остановился предыдущий вызов)
  работает идентично потоковой записи; произвольные seek-подобные
  сценарии (перезапись СЕРЕДИНЫ уже большого файла) корректны, но каждый
  вызов — O(размер файла), а не O(записываемого куска). Это сознательное
  упрощение по сравнению с Odin (реальный дескриптор + `os.write` на
  текущей позиции ядра) — приемлемо, пока в Zig-VM вообще нет фонового
  worker pool'а (T038) и все `фс.*` и так однократно блокирующие; вернуться
  к позиционному дескриптору стоит вместе с портированием T038/T039, если
  где-то понадобится потоковая запись больших файлов.
- `.закрыть()` — просто `is_open = false`, нет OS-ресурса для
  освобождения (сравните с Odin: `close_file_value`, финализатор GC).
  `.закрыть()` дважды — идемпотентный no-op, как и раньше.
- `фс.открыть(путь)` — `Dir.access` для проверки существования; если файла
  нет, создаёт пустой через `Dir.writeFile(..., data="")` (не трогает
  существующее содержимое, если файл уже есть — то же самое, что Odin's
  `os.open(path, {.Read, .Write, .Create}, ...)` без truncate).

Новые e2e-тесты в `runner.zig`: открыть/записать/закрыть/переоткрыть/
прочитать_строку×2/прочитать (проверяет и последовательность строк, и
корректный курсор через переоткрытие), повторная запись поверх уже
существующего файла без переоткрытия (проверяет позиционную перезапись —
`"abcdef"` → записать `"XY"` на позиции 0 → `"XYcdef"`), чтение после
`.закрыть()` (`"файл уже закрыт"`, тот же текст ошибки, что и у
`Результат.Неудача` из fs-модуля), плюс browser-rejection тест на
`фс.открыть`. `zig build test`/`conformance`/`lsp`/`browser` — все зелёные.

Не сделано (сознательно вне рамок этой правки): нет target-теста specific
к file-методам (`.прочитать`/`.записать`/`.закрыть` сами по себе не incur
никакой target-проверки — недостижимы в browser-таргете вообще, поскольку
`фс.открыть` уже отклоняется на этапе тайпчека, единственного способа
получить значение типа `Файл`).


## Модуль ос: аргументы/версия_паноса/окружение/установить_окружение/удалить_окружение/выполнить/завершить

Первый non-filesystem native adapter на Zig-стороне (T039) — весь модуль `ос`, 7 функций, тем же вертикальным срезом (resolver export -> type_checker сигнатура -> bytecode опкод -> vm.zig runtime), что и `фс.*` в предыдущих срезах. `target.zig` уже ЗАРАНЕЕ содержал имена `ос::окружение`/`ос::установить_окружение`/`ос::удалить_окружение`/`ос::выполнить`/`ос::завершить` в списке `native_only` (видимо записано во время проектирования T037/T039 заранее) — ни одной правки в `target.zig` не понадобилось; `ос::аргументы`/`ос::версия_паноса` НЕ входят в этот список (доступны на любом таргете, включая browser — подтверждено новым тестом), симметрично Odin'овской `builtin_availability.odin`.

### Новое понимание: `if`/`else` с comptime-условием ДЕЙСТВИТЕЛЬНО устраняет недостижимую ветвь — но `if (comptime x) { return; }` без `else` НЕТ

Прошлая находка (файловый дескриптор, см. выше) была неверно интерпретирована как "весь код после `if (comptime freestanding) { ...; return; }` всё равно анализируется для любого таргета". Для `ос.окружение`/`установить_окружение`/`удалить_окружение` понадобились РЕАЛЬНЫЕ libc extern'ы (`std.c.getenv` + собственные `extern "c" fn setenv/unsetenv`, которых в `std.c` просто нет) — это либо работает только через настоящее устранение мёртвой ветки на этапе Sema, либо ломает `wasm32-freestanding` (там либа вообще не слинкована). Переписал ВСЕ новые `ос.*` функции с явным `if (comptime builtin.target.os.tag == .freestanding) { ... } else { ...реальный extern-вызов... }` — с явной веткой `else`, а не паттерном "early return, потом код дальше" — и `zig build browser` собрался чисто. Это ПОДТВЕРЖДАЕТ, что именно форма `if`/`else` (а не одиночный `if` с ранним `return`) даёт Zig'у настоящее устранение недостижимой ветки на уровне Sema — известный, но здесь впервые эмпирически проверенный на этом дереве кода факт. Существующие `фс.*` срезы, использующие старую форму (`if (comptime freestanding) { fault; return; }` БЕЗ `else`, код продолжается ниже), продолжают работать только потому что вызываемые ими API (`std.Io.Dir.readFileAlloc`/`.writeFile`/`.access`/`.deleteFile` и т.п.) сами по себе НЕ содержат freestanding-несовместимого кода — это везение конкретных std-функций, а не структурная защита. Не переписывал существующие срезы задним числом (не в объёме этой правки, поведение не меняется), но задокументировал здесь для следующего native adapter (T039 продолжение — process/compression/syntax): использовать настоящий `if`/`else`, если внутри реальный target-специфичный API.

### Реализация

- **`ос.аргументы()`** — `Массив(Строка)`, без target-guard'а (доступен везде). Новое поле `Vm.program_args: []const []const u8 = &.{}` (по умолчанию пусто — LSP/browser не имеют осмысленного argv, как и у Odin), заполняется ТОЛЬКО из `zig/cli/main.zig`'s `main()`: цикл по оставшимся `arguments.next()` ПОСЛЕ пути к файлу, каждая строка dup'ится через `init.gpa` (иначе указывала бы во внутренний буфер `Args.Iterator`, инвалидируемый его `deinit()` до конца выполнения VM).
- **`ос.версия_паноса()`** — захардкожена `"0.2.16"`, синхронизировать руками с Odin'овской `PANOS_VERSION` (`core/vm.odin`) — общего источника истины между двумя реализациями пока нет.
- **`ос.окружение(имя)`** — `Опция(Строка)` через `std.c.getenv`; новый общий хелпер `Vm.pushOption` (симметричен `pushSuccessResult`/`pushErrorResult` — тот же `Опция.Есть`/`Опция.Нет` tagged-aggregate паттерн, что уже использует `queueSignal`).
- **`ос.установить_окружение(имя, значение)`**/**`ос.удалить_окружение(имя)`** — `extern "c" fn setenv/unsetenv` в новом файловом неймспейсе `posix_env` (не struct-метод, просто группировка деклараций, референсится только из non-freestanding `else`-веток).
- **`ос.выполнить(программа, аргументы, рабочая_директория)`** — `std.process.run(gpa, io, .{ .argv = ..., .cwd = .{ .path = working_dir } })`, даёт `RunResult{ term, stdout, stderr }` — код завершения нормализуется из `Child.Term` (`.exited`/`.signal`/`.stopped`/`.unknown`, сигнальные варианты как `128 + номер_сигнала`, условность не документирована нигде специально, только внутренняя нормализация для единообразного `Число`) в плоский tuple `(Число, Строка, Строка)`, обёрнутый в `Результат(..., Ошибка)` — тот же "сырые данные, не именованная структура" принцип, что у Odin (`core/stdlib.odin`'s комментарий про `сеть::http_запрос`).
- **`ос.завершить(код)`** — `std.process.exit(...)`, тип `Никогда` (`builtins.never`), симметрично `паника`.
- Новый общий хелпер `Vm.pushErrorResultForModule(module, message)` — старый `pushErrorResult` жёстко подставлял `"фс"` как код ошибки (единственный вызывающий модуль на тот момент); теперь это тонкая обёртка над параметризованной версией, `ос.*`-ошибки используют модуль `"ос"`.

### Тесты

Новые e2e-тесты в `runner.zig`: `ос.аргументы()` без установленного `program_args` (пустой массив — покрывает опкод сам по себе, реальный CLI-путь проверен вручную через `zig build run -- файл.ps арг1 арг2 арг3` → `длина() == 3`), `ос.версия_паноса()` (непустая строка), полный круг `установить_окружение`→`окружение`→`удалить_окружение`→`окружение` (значение появляется, затем пропадает), `ос.выполнить("/bin/echo", ...)` (реальный дочерний процесс, вывод сверен буквально), `ос.выполнить` с несуществующей программой (`Результат.Неудача`, не паника), browser-rejection на `окружение`/`выполнить`/`завершить`, browser-ALLOW на `аргументы`/`версия_паноса` (типизируются успешно на `.browser_interpreter` — единственный существующий тест такой формы, остальные browser-тесты в этом файле все про отклонение). `zig build test`/`conformance`/`lsp`/`browser` — все зелёные.

Не сделано: реальный `zig build browser` — это только КОМПИЛЯЦИЯ .wasm артефакта, не проверка, что получившийся модуль реально инстанцируется в настоящем браузере (`extern "c"` символы БЕЗ линкованной libc на freestanding-таргете технически становятся неразрешённым wasm-импортом, если попадают в скомпилированный вывод — раз `zig build browser` прошёл чисто, это значит ветка с ними была устранена на этапе Sema и в скомпилированный `.wasm` вообще не попала, но живой `wasmtime`/browser-инстанцирующий тест этого явно не подтверждает дополнительно; полагаться стоит на факт успешной сборки + понимание механизма `if`/`else`-устранения, а не считать это окончательно верифицированным до появления настоящих wasmtime-тестов, тех же, что нужны для T044).

## сжатие.разжать_gzip

Второй T039-срез. `сжатие.разжать_gzip(текст) -> Результат(Строка, Ошибка)` — тот же вертикальный срез, что `ос.*`, но заметно проще: `std.compress.flate.Decompress.init(&input_reader, .gzip, &.{})` (`&.{}` — пустой window-буфер, direct-режим, подтверждено тестом самой std на whole-stream decompress через `Writer.Allocating` — `std/compress/flate/Decompress.zig`'s `testDecompress`) + `.reader.streamRemaining(&writer)` в `std.Io.Writer.Allocating`.

В отличие от `фс.*`/`ос.*`, здесь НЕ понадобился ни `std.Io.Threaded`, ни comptime-freestanding branch вообще — `std.compress.flate` работает целиком в памяти (вход — уже полученная `Строка` с сырыми байтами, выход — новая `Строка`), никакого обращения к ОС. `target.zig` тем не менее по-прежнему помечает `сжатие::*` как `native_only` (префиксная проверка уже была) — это ограничение unchanged от Odin (`vm_compress_wasm.odin`: `core:compress/gzip` транзитивно тянет `core:os` и падает под `js_wasm32`), не Zig-специфичная необходимость; сохранил ту же политику для паритета, а не потому что Zig-реализация физически этого требует.

Единственная непростая часть — тестирование: `Строка`-литерал в исходнике panos не может содержать произвольные gzip-байты (не валидный UTF-8), поэтому тест не встраивает их текстом в `.ps`-исходник, а пишет реальный `.gz`-файл на диск и читает его через уже существующий `фс.прочитать` — ровно тот путь, каким эта функция и будет использоваться на практике.

Новые тесты в `runner.zig`: полный круг `фс.прочитать` (реальный `.gz`-файл с байтами для `"hello world"`, сгенерированными Python'овским `gzip.compress`) → `сжатие.разжать_gzip` → сравнение с исходной строкой; `Результат.Неудача` на невалидном gzip-вводе (не паника); browser-rejection. `zig build test`/`conformance`/`lsp`/`browser` — все зелёные.

## синтаксис.* — компилятор гоняет сам себя на другой файл

Последний T039-срез — все 6 функций: `структуры`, `поля`, `аннотации`, `аргумент_аннотации`, `аннотации_поля`, `аргумент_аннотации_поля`. compile-time АСТ-интроспекция ДРУГОГО `.ps`-файла (не текущей программы) для codegen-инструментов на panos (см. Odin's `core/vm_syntax_native.odin`). Без персистентного хендла — каждый вызов заново читает и парсит путь.

Реализация переиспользует уже существующий фронтенд ЦЕЛИКОМ — `lexer.tokenize`+`parser.parse` (те же функции, что используются для компиляции РЕАЛЬНОЙ выполняемой программы) вызываются на содержимом стороннего файла, ошибки лексера/парсера (первая diagnostic) оборачиваются в `Результат.Неудача`, найденная `тип X = структура` декларация возвращает имена полей + `type_node_to_string`-подобный рендер типа (просто синтаксис как написан, НЕ канонический `TypeId` тайпчекера — для этого файла тайпчекер вообще не запускается) + список аннотаций + первый строковый позиционный аргумент конкретной аннотации.

### Единственная реальная сложность: имя `lexer`/`parser`/`ast` уже занято

Первая попытка добавить `const lexer = @import("lexer.zig");`/`const parser = @import("parser.zig");`/`const ast = @import("ast.zig");` на уровне модуля `vm.zig` сломала компиляцию — файл уже содержит 48+ тестов, каждый из которых делает СВОЙ локальный `const lexer/parser/ast = @import(...)` (написано до появления module-scope импортов), и Zig репортит "local constant shadows declaration". Решение — переименовал импорты в `ast_types`/`syntax_lexer`/`syntax_parser` (имена, точно не занятые нигде в файле) вместо переименования полусотни существующих тестов.

### Тесты

Новые e2e-тесты в `runner.zig`: полный круг всех 6 функций на реальном файле, написанном на диск (структура с `&Json("товар")` + поле с `&Json("название_поля")`, все 6 вызовов последовательно, вложенных друг в друга, результат сверен буквально); `Опция.Нет` для отсутствующей аннотации; `Результат.Неудача` (не паника) для отсутствующей структуры, отсутствующего поля, несуществующего файла и файла с синтаксической ошибкой в НЁМ (не в текущей программе); browser-rejection для всех 6 builtin'ов сразу (таблично, arity на каждый). `zig build test`/`conformance`/`lsp`/`browser` — все зелёные.

Этим закрыт весь исходный список T039 (filesystem/process/compression/syntax) — все adapter'ы функционально готовы, хотя и не как отдельные файлы `zig/core/native/*.zig`, как изначально сформулировано в tasks.md — всё живёт инлайново в `vm.zig`, тем же паттерном, что и с T037. Следующий natural next step — T040 (сеть/HTTP, вероятно после решения по scheduler'у/T038) или T041 (SQLite/FFI, vendored C-библиотеки).

## сеть.подключиться + Соединение.получить/получить_строку/отправить/закрыть + сеть.кодировать_url

Первый T040-срез (network) — TCP-клиент. `сеть.кодировать_url` — тривиальная чистая функция (RFC 3986 percent-encoding побайтово), без target-guard'а. `сеть.подключиться(хост, порт) -> Результат(Соединение, Ошибка)` — новый opaque-тип `Соединение` (симметрично `Файл`), через `std.Io.net.IpAddress.resolve`+`.connect(.{.mode=.stream})`.

### Почему `Соединение` НЕ может переиспользовать `FileHandle`'s трюк "переоткрыть по пути"

`Файл` не хранит живой OS-дескриптор — каждый метод заново читает файл ЦЕЛИКОМ по пути (см. выше). Для сокета это невозможно: once байты считаны с провода, они исчезли навсегда — повторное `connect()` — НОВОЕ соединение, пустой разговор, а не продолжение старого. `Соединение` вынужденно хранит живой `std.Io.net.Stream` (простое POD-поле, безопасно).

Тонкость: `.получить_строку()` не может просто сконструировать свежий `Stream.Reader` с непустым внутренним буфером на каждый вызов — `Reader` при непустом буфере может УСПЕШНО вычитать с сокета БОЛЬШЕ, чем запрошено (opportunistic readahead в собственный буфер), и раз `Reader` — временный объект на стеке функции, эти лишние байты потерялись бы безвозвратно при следующем вызове. Решение — свой собственный буфер `Connection.pending: std.ArrayList(u8)` (обычные данные, не `Io.Reader`), а `Stream.Reader`/`.Writer` конструируются ТОЛЬКО с нулевым буфером (`&.{}`) — это заставляет `readSliceShort` читать РОВНО столько байт, сколько запрошено, без readahead (тот же принцип "direct mode", что нашли раньше в `File.Reader`/`Decompress`). `.получить_строку()` сканирует `pending` на `\n`, при отсутствии — читает ещё один чанк в `pending` и повторяет; на EOF отдаёт остаток `pending` как есть (тот же контракт, что у `Файл`/Odin — EOF не ошибка, просто пустая строка); `.получить()` сначала забирает то, что уже скопилось в `pending` от предыдущих вызовов `.получить_строку()`, потом дочитывает до реального EOF.

`.отправить(текст)`/`.закрыть()` — тем же паттерном (`writer(io, &.{})`+`writeAll`+`flush`; `stream.close(io)`). GC-финализатор (`gc.zig`) закрывает сокет, если `.закрыть()` не был вызван явно — здесь, в отличие от `Файл`, это НЕ no-op (см. `value.zig`'s `Connection` doc comment).

Все конструкции `Stream.Reader`/`.Writer`/`Threaded.close` — внутри настоящего `if`/`else` на `builtin.target.os.tag == .freestanding` (не early-return-then-fallthrough) — тот же урок, что закреплён на `ос.*` — `zig build browser` подтверждает, что это работает.

### Тесты

Живьём проверено вручную (не автоматизированный тест — см. ниже почему): реальный Python `socket`-сервер на 127.0.0.1, `сеть.подключиться`+`.отправить`+`.получить`+`.закрыть` через `zig build run` — эхо прошло байт-в-байт. Автоматизированные тесты в `runner.zig`: `сеть.кодировать_url` (несколько зарезервированных байт); `Результат.Неудача` при подключении к порту 1 (детерминированный connection-refused, без необходимости живого слушателя в тесте — сам тест-раннер не имеет фонового accept-loop, а заводить его специально ради теста сочтено overkill для клиентской части, когда happy path уже проверен вручную); browser-rejection на `подключиться`; browser-ALLOW на `кодировать_url`. `zig build test`/`conformance`/`lsp`/`browser` — все зелёные.

Не сделано: `сеть.http_запрос` (HTTP(S)-клиент через `std.http.Client`), `сеть.http_сервер_слушать` (нужен настоящий concurrency-дизайн — листенер должен принимать соединения, не блокируя единственный VM-поток, что сейчас нечем сделать без scheduler'а/T038) — оба остаются в T040.

## сеть.http_запрос — HTTP(S)-клиент через std.http.Client

Второй T040-срез. `сеть.http_запрос(метод, url, тело, заголовки) -> Результат((Целое, Массив((Строка,Строка)), Строка), Ошибка)` — в отличие от Odin (векторит внешнюю C-библиотеку `external/odin-http` + OpenSSL для https), Zig-версия использует ЧИСТЫЙ `std.http.Client` из стандартной библиотеки — HTTPS/TLS, редиректы, chunked encoding, gzip/deflate/zstd-декомпрессия ответа — всё уже реализовано в std, вендорить нечего.

Реализация: `client.request(method, uri, .{.extra_headers=...})` → `.sendBodyUnflushed`/`.sendBodiless` (тело есть/нет) → `.receiveHead(redirect_buffer)` → заголовки ответа через `response.head.iterateHeaders()` (плоский `Массив((Строка,Строка))`, тот же "сырые данные, не именованная структура" принцип, что у `ос.выполнить`) → тело через `response.readerDecompressing(...)` + `.streamRemaining` в `std.Io.Writer.Allocating` (тот же паттерн, что уже использован в `сжатие.разжать_gzip`). Метод — `std.meta.stringToEnum(std.http.Method, ...)` после приведения к верхнему регистру; неизвестный метод — `Результат.Неудача`, не паника.

Полностью синхронный (блокирующий) вызов — как и `сеть.подключиться`, никакого async/scheduler (T038 не начат). `if`/`else` на comptime-freestanding вокруг всего тела (тот же урок с `ос.*`) — `zig build browser` подтверждает, что `std.http.Client`/TLS-код устраняется на этапе Sema для wasm32-freestanding и не мешает сборке браузерного интерпретатора, хотя сам по себе точно не собрался бы под этот таргет.

### Тесты

Живьём проверено вручную: реальный локальный `python3 -m http.server`, `сеть.http_запрос("GET", "http://127.0.0.1:<порт>/index.html", "", ...)` вернул правильное тело файла байт-в-байт. Автоматизированные тесты в `runner.zig`: `Результат.Неудача` при недоступном хосте (порт 1), при неизвестном HTTP-методе, при некорректном URL; browser-rejection. Полностью автоматизированный happy-path тест потребовал бы поднять настоящий `std.http.Server`-accept-loop в фоновом потоке ВНУТРИ теста — решил, что это не стоит сложности при уже выполненной живой проверке (тот же trade-off, что и в TCP-срезе выше). `zig build test`/`conformance`/`lsp`/`browser` — все зелёные.

## бд.открыть/выполнить/запрос/закрыть — SQLite через прямую компиляцию амальгамации

Первая половина T041. `бд.открыть(путь) -> Результат(Соединение_БД, Ошибка)`, `Соединение_БД.выполнить(sql, параметры) -> Результат(Число, Ошибка)`, `.запрос(sql, параметры) -> Результат(Массив(Соответствие(Строка, Строка)), Ошибка)`, `.закрыть() -> Пусто`. Контракт полностью совпадает с Odin (`core/vm_sql_native.odin`): параметры биндятся ТОЛЬКО позиционно через `?` (нет ни одного пути строковой конкатенации SQL нигде в этой VM — SQL-инъекция структурно невозможна, не просто избегается по соглашению), `NULL`-колонка пропускается в результирующей `Соответствие` целиком (не `""`), `BLOB`-колонка проваливает весь `.запрос()` с `Ошибка("бд", "BLOB-колонки не поддержаны в этой версии")` — то же самое сообщение, что у Odin. В отличие от Odin (async worker-pool, `in_flight`/`close_requested`), Zig-версия полностью синхронная — тем же упрощением, что `Файл`/`Соединение` (нет scheduler'а/T038).

### Новый файл `zig/core/sqlite3_bindings.zig`

Ручные `extern "c" fn` объявления на нужное подмножество SQLite C API (`sqlite3_open_v2`/`_close_v2`/`_errmsg`/`_prepare_v2`/`_bind_text`/`_step`/`_column_count`/`_column_name`/`_column_type`/`_column_text`/`_finalize`/`_changes`), не `@cImport` — тот же приём, что уже используется для `setenv`/`unsetenv` в `vm.zig`. Одна реальная техническая сложность: SQLite's `SQLITE_TRANSIENT` — это НЕ настоящий колбэк, а специальное значение `(void(*)(void*))-1` ("скопируй строку немедленно"), которое sqlite никогда не вызывает — но `@ptrFromInt` на адрес из всех единиц в РЕАЛЬНЫЙ тип указателя на функцию Zig отказывается компилировать на этапе comptime (`@alignCast` не пропускает заведомо невыровненный адрес, даже если он по факту никогда не разыменовывается). Решение — объявить параметр `destructor` в `sqlite3_bind_text` как голый `?*anyopaque`, а не честную сигнатуру `void(*)(void*)`: ABI указателя идентично в любом случае (просто указатель машинного слова), а `*anyopaque` не накладывает требований выравнивания — `@ptrFromInt(maxInt(usize))` компилируется без проблем.

### build.zig: своя статическая библиотека, только для native-таргетов

`external/sqlite3/sqlite3.c` (уже вендорена для Odin, тот же файл) компилируется В ОТДЕЛЬНУЮ маленькую статическую библиотеку (`b.addLibrary`+`addCSourceFile`), а не добавляется напрямую в общий `core_module` — `core_module` ИСПОЛЬЗУЕТСЯ И browser-исполняемым файлом (`wasm32-freestanding`), который физически не может скомпилировать/слинковать настоящую C-амальгамацию (нет libc). `.link_libc = true` + `.linkLibrary(sqlite_lib)` навешаны ТОЛЬКО на нативные `Compile`-шаги, которые реально доходят до `vm.zig` — `panos`, `lsp`, и отдельно `vm_unit_tests`/`module_compiler_unit_tests`/`runner_unit_tests`/`browser_tests` (эти четыре компилируют файл напрямую по `root_source_file`, не через общий модуль, поэтому нуждаются в собственных, отдельно навешанных флагах). Для `core_tests` (единственный тест, буквально использующий `core_module` КАК ЕСТЬ в качестве `root_module`) заведён отдельный `core_test_module` — та же `root.zig`, но СВОЙ объект `Module`, чтобы не мутировать шаренный `core_module` (который использует и `browser`).

### Тесты

Живьём проверено на реальном файле `.sqlite` через `zig build run`: `CREATE TABLE`+два `INSERT` (один с `NULL`-колонкой)+`SELECT ... ORDER BY`+чтение обеих строк — сортировка, `NULL`-пропуск и `.есть()`/`.получить()` на результирующих `Соответствие` все корректны. Автоматизированные тесты в `runner.zig`: тот же полный CRUD-круг (реальный файл на диске, не мок); `Результат.Неудача` на синтаксически неверном SQL; `Результат.Неудача` на вызове метода после `.закрыть()` (не паника); `Результат.Неудача` на недействительном пути открытия; browser-rejection. `zig build test`/`conformance`/`lsp`/`browser` — все зелёные, включая нативный `zig build browser`-компиляцию (подтверждает, что `sqlite3.c` НЕ попадает в wasm-сборку).

libffi (вторая половина T041) — см. следующий раздел ниже, теперь готова для scalar-only среза.

## внешний (FFI) — libffi, scalar-only первый срез

Вторая половина T041. `внешний "lib" функ имя(...) -> Marshal` — полный вертикальный срез, но структурно другой, чем остальные native-адаптеры: библиотека, которую грузит `внешний`, ПРОИЗВОЛЬНАЯ и задаётся ПОЛЬЗОВАТЕЛЬСКИМ кодом (не одна из вендоренных зависимостей проекта) — резолвится настоящей рантайм-загрузкой (`std.DynLib`), не компилируется/линкуется статически.

### Где что живёт

- **`resolver.zig`**: новая `resolveForeignFunction` (вызывается из `predeclare`'s `.foreign`-ветки) — грузит `foreign.library` через `std.DynLib.openZ`, резолвит `foreign.name` через `.lookup(*anyopaque, ...)`, кэширует адрес как `usize` в новом поле `Resolution.foreign_functions: std.AutoHashMap(SymbolId, usize)`. Загруженная библиотека НИКОГДА не закрывается (тот же контракт, что у Odin's `module_graph.foreign_libraries` — закрытие может реально выгрузить библиотеку из памяти, обнулив уже выданные указатели на функции).
- **`type_checker.zig`**: новая `defineForeignSignature`/`foreignMarshalType` — строит настоящую функциональную сигнатуру из `ForeignParam.marshal` (Int8/32/64 -> `Целое`, Float32/64 -> `Число`, CString -> `Строка`). AST-поддержка (`Decl.foreign`/`ForeignParam`/`ForeignMarshalKind`) уже существовала с самых ранних фаз портирования парсера — недостающим было именно ЭТО, typecheck полностью игнорировал `.foreign` (`.foreign => {}`).
- **`bytecode.zig`**: новый `Constant.foreign_function` (fn_ptr + marshal-кинды параметров/возврата, arena-owned — копия из `Resolution`, не ссылка, чтобы скомпилированная `Program` была самодостаточна и не зависела от времени жизни `Resolution`) и новый опкод `call_foreign`.
- **`compiler.zig`**: новая `compileForeignCall`, перехватывает вызов ДО generic function-call fallback — `внешний`-декларации регистрируются резолвером как обычные `.function`-символы (нет отдельного вида символа), поэтому единственный способ отличить `внешний`-вызов — реверсивный обход `decl_symbols` (тот же linear-scan паттерн, что уже использует LSP's `definitionSpan`) и проверка, что декларация — именно `.foreign`.
- **`zig/core/ffi_bindings.zig`** (новый файл) — `FfiType`/`FfiCif` layout вручную (Apple AArch64 добавляет отдельное поле `aarch64_nfixedargs` в CIF — тот же нюанс, что у Odin's `core/ffi_bindings.odin`), `ffi_get_default_abi`/`ffi_prep_cif`/`ffi_call`/`ffi_get_struct_offsets` extern'ы.
- **`vm.zig`**: `callForeign`+`invokeForeign` — маршалинг ровно по Odin'овской схеме (`core/vm_ffi_native.odin`): одна 8-байтная ячейка на скалярный аргумент, `avalue` — массив АДРЕСОВ этих ячеек (libffi хочет указатели НА аргументы, не значения), `КСтрока`-аргументы копируются в null-terminated буфер, живущий до конца `ffi_call`.

### build.zig: PREBUILT-архив, не компиляция из исходников

В отличие от sqlite3 (амальгамация, компилируется прямо здесь), libffi вендорена как ГОТОВЫЙ статический архив на платформу (`external/libffi/lib/<platform>/libffi.{a,lib}`, тот же набор платформ, что уже был у Odin-версии) — добавляется через `addObjectFile` напрямую в те же native-only `Compile`-шаги, что уже получают `sqlite_lib`, без отдельного `addLibrary`-шага (нечего собирать, просто слинковать существующий файл).

### Сознательно НЕ перенесено в этом срезе: `Указатель(T)` и структуры по значению

Odin's `внешний` — реальный, но ДВУХСТАДИЙНЫЙ функционал: скалярные типы появились первыми ("Стадия 47"), `Указатель(T)`/struct-by-value — отдельными более поздними добавлениями ("Стадия 49"/"Стадия 51"). У ЭТОЙ Zig VM пока в принципе нет рантайм-представления указателя (`value.zig` не содержит `.pointer`-варианта) — добавлять его только ради `внешний`, без остального контекста, где `Указатель(T)` мог бы использоваться, было бы преждевременным расширением объёма. `.pointer`/`.struct_value` marshal-кинды поэтому ОТКЛОНЯЮТСЯ на этапе type-check с понятной `Type Error`, а не молча падают в рантайме — симметрично тому, как `.struct_value` уже отклоняется.

### Побочная находка: `checkSourceForTarget` не долетал до резолвера

Первая версия guard'а использовала только `comptime builtin.target.os.tag == .freestanding` — защищает РЕАЛЬНУЮ wasm-сборку (`zig build browser` собрался чисто), но `checkSourceForTarget(..., .browser_interpreter)` (LSP-стиль симуляции "а что если это для браузера") выполняется ВНУТРИ обычного нативного тестового бинарника — comptime-условие там никогда не истинно, и тест browser-rejection падал (резолвер реально пытался грузить библиотеку). Оказалось, что `resolver.zig` ВООБЩЕ не имел понятия о целевом таргете — `target_profile` нигде не долетал от `module_compiler.zig`'s `compileGraphForTarget` до `resolver.resolveModule`. Добавил `resolveModuleForTarget` (новый параметр, `resolveModule` — тонкая обёртка с `.native` по умолчанию, ничего не ломает у существующих вызывающих) + поле `Resolver.target_profile`, и теперь `resolveForeignFunction` проверяет ОБА условия: comptime-freestanding (настоящая wasm-сборка) И рантайм `target_profile != .native` (симулированные нативным бинарником таргеты).

### Тесты

Живьём проверено через `zig build run` на РЕАЛЬНОЙ `libc`: `abs(-42) == 42`, `getenv` на существующую/отсутствующую переменную (последнее поймало реальный сегфолт — NULL-возврат С-строки крашил `std.mem.span` на нулевом указателе; исправлено — NULL `КСтрока`-возврат становится пустой `Строка`, не паникует). Автоматизированные тесты в `runner.zig`: `abs()` (Int32 туда-обратно), `strlen()`/`getenv()` (КСтрока туда-обратно, включая случай отсутствующей переменной без падения), `Resolve Error` на несуществующей библиотеке/символе (не паника, не Type Error — правильная фаза диагностики), browser-rejection. `zig build test`/`conformance`/`lsp`/`browser` — все зелёные.
## Планировщик процессов: recursive-run-to-completion → round-robin coroutines

Не отдельная speckit-задача — предпосылка для неблокирующего actor I/O (обсуждение с пользователем: BEAM VM однопоточная, не блокируется на I/O, но и не блокируется через thread-pool-per-call — хотел то же самое здесь, без Odin-style `core:thread.Pool`-порта в лоб). Первым шагом обнаружилось, что порт `Await_Async` вообще невозможен без этого: Zig-версия VM (в отличие от Odin, T027) до этой правки НЕ имела настоящего planировщика — `спавн()`/`отправить()` запускали целевой процесс РЕКУРСИВНО, синхронно, до конца обработки одного сообщения (`runProcess`, теперь удалён), используя общий `vm.stack`/`vm.frames` как временный scratch, сохраняемый/восстанавливаемый вокруг рекурсивного вызова. Как следствие, `получить()` не умел ЖДАТЬ сообщение — при пустом mailbox сразу `Runtime Error` (фейл-фаст), поскольку процесс запускался ТОЛЬКО в момент, когда сообщение уже гарантированно доставлено.

### Что изменилось

- **`value.zig`**: `Frame` (function_id/ip/locals) переехал сюда из `vm.zig` — `Process` теперь хранит СОБСТВЕННЫЕ `frames: std.ArrayList(Frame)`/`stack: std.ArrayList(Value)` (персистентное продолжение), плюс `has_run: bool` и `async_results: std.ArrayList(Value)` (задел под будущий `Await_Async` — очередь, отдельная от mailbox/signals, тем же мотивом, что и у Odin: результат async-вызова не должен перепутаться с обычным сообщением, пришедшим, пока процесс ждал).
- **`vm.zig`**: `step()` теперь возвращает `StepOutcome` (`none`/`completed: Value`/`suspended`) вместо `?Value`. Три инструкции — `получить`, `получить_сигнал`, (будущий `Await_Async`) — при пустой очереди возвращают `.suspended`, предварительно откатив `frame.ip -= 1` (step() инкрементирует ip БЕЗУСЛОВНО перед диспетчеризацией, в отличие от Odin, где инкремент — вручную в каждом case; откат нужен, чтобы та же инструкция переисполнилась при следующем шансе на выполнение).
- Новый `runProcessSlice` — свопает `process.stack`/`process.frames` в `vm.stack`/`vm.frames` (тот же приём, что Odin's `run_scheduler`), крутит `step()` до `.completed`/краша/`.suspended`, свопает обратно — ПОЛНОЙ передачей владения (`process.stack = self.stack; ...; self.stack = .empty;`), не просто копией заголовка: иначе `Vm.deinit()` и `Process.deinit()` освобождают один и тот же буфер дважды (поймано `DebugAllocator`'ом как "Double free detected" при первом прогоне тестов).
- Новый `runScheduler` — round-robin по `vm.processes`, критерий "есть что делать" ровно как у Odin: `!has_run || mailbox/signals/async_results не пусты`. Возвращает управление, как только ЗАВЕРШАЕТСЯ или ПАДАЕТ корневой процесс (индекс 0) — осиротевшие процессы просто брошены, тот же контракт, что был раньше. Deadlock-guard (никто не готов И нет async I/O в полёте) — новое поведение, раньше было структурно невозможно (никакого `.suspended` не существовало).
- `отправить()` больше НЕ запускает целевой процесс — только кладёт сообщение в mailbox, планировщик подберёт на следующем проходе. Это и есть основной наблюдаемый эффект для существующих программ: любой код, полагавшийся на СИНХРОННОСТЬ побочных эффектов после `отправить()` (до этой правки — реальная гарантия реализации, никогда не документированный контракт языка), теперь может увидеть другой порядок событий.
- `async_pool`/`drainAsyncCompletions`/`hasPendingAsyncIo`/`blockForOneAsyncCompletion`/`joinAsyncPool` — пока заглушки (no-op), задел под следующий срез (`core:thread.Pool`-аналог + `Await_Async`).

### Побочная находка: тест "cascades linked process failures" был завязан на старую рекурсивную семантику

Тест спавнил связанный процесс, который сам крашился ПОСЛЕ того, как его родитель уже успевал нормально завершиться (при старой рекурсивной модели — успевать не мог, `отправить()` блокировался до конца каскада). При настоящем round-robin родитель мог УСПЕТЬ завершиться штатно ДО того, как его линк крашился — `terminate_process`'ов guard (`if process.status != .ready return`) тогда молча гасит каскадное уведомление, потому что цель уже не `ready`. Оказалось, что Odin's СОБСТВЕННЫЙ эквивалентный тест (`core/e2e_actors_test.odin:687`, `test_link_cascades_crash_to_linked_process`) уже решает ровно эту проблему явным ping-рандеву: связанный партнёр НИКОГДА не завершается сам (зацикливается через рекурсивный вызов после каждого `получить()`), поэтому гарантированно жив, когда бы ни случился крах. Не баг планировщика — тест переписан по образцу Odin-теста (партнёр `сосед` вместо однократного `связанный`, зацикливается вместо завершения).

### Тесты

`zig build test`/`conformance`/`lsp`/`browser` — все зелёные (845/845 после правки одного теста). Наблюдаемого регресса поведения для существующих корректных программ нет — единственный сломавшийся тест полагался на недокументированную деталь реализации, не на языковой контракт.

## Неблокирующий I/O: воркер-пул + Await_Async (первый срез — фс.прочитать/фс.записать)

Продолжение планировщика выше — теперь, когда есть настоящий suspend/resume, можно перенести Odin's `Await_Async`-дизайн. Тот же принцип, что у Odin (`core:thread.Pool` + канал завершений), НЕ буквальный порт кода — Zig 0.16 убрал `Mutex`/`Condition`/`Semaphore` из `std.Thread` целиком, они переехали в `std.Io` (`lock`/`wait`/`signal` теперь принимают `Io`-хендл, маршрутизируются через `io.futexWait`/`futexWake`). Раз в API больше нет "голого" ОС-мьютекса без `Io`, каждый метод `AsyncQueue` строит одноразовый `std.Io.Threaded` только чтобы получить `Io`-хендл — futex адресуется по адресу разделяемого атомика, а не по тому, какой именно `Threaded`-инстанс его вызвал, так что вызовы с главного потока и с воркер-потоков (каждый — свой одноразовый `Threaded`) корректно синхронизируются через одно и то же состояние `Mutex`/`Condition`. Тот же приём "одноразовый Threaded на вызов", что уже применяется по всему файлу для настоящего I/O.

### Аллокатор воркер-потока — НЕ Vm.allocator

Та же проблема, что Odin явно решил через `vm_heap_allocator()` (см. `core/gc.odin`): `Vm.allocator` может быть (и в CLI является) НЕ потокобезопасным. `AsyncQueue` и всё, что видит воркер-поток (`path`/`content`-копии, прочитанные байты, текст ошибки), живёт ЦЕЛИКОМ на `std.heap.page_allocator` — отдельно от `Vm.allocator`. Доставка (`deliverAsyncResult`/`buildAsyncResultValue`, ГЛАВНЫЙ поток) копирует байты в GC-строку через `self.heap`/`self.allocator` и сразу освобождает `page_allocator`-буферы (`freeAsyncPayload`).

### Компилятор: одна submit-инструкция + ОДНА общая await_async

`фс.прочитать`/`фс.записать` — то же имя builtin'а, никакого нового синтаксиса: `compileFilesystemBuiltin` (`compiler.zig`) теперь эмитит `file_read_submit`/`file_write_submit` + `await_async` вместо старого синхронного `file_read`/`file_write`. `await_async` — ОДНА инструкция на ВСЕ будущие async-builtin'ы (результат приходит из `process.async_results`, FIFO) — работает, потому что submit и await ВСЕГДА эмитятся смежной парой, гарантируя порядок.

### Побочная находка: та же ловушка if/else, новый победитель

`AsyncQueue.drain`/`hasPending`/`waitForOne`/`joinAll` вызываются БЕЗУСЛОВНО из `run()`/`run_scheduler` для ЛЮБОГО таргета (в отличие от `beginSubmit`/`push`, которые достижимы только из `submitFileRead`/`submitFileWrite`, а те — уже за freestanding-гейтом в `fileReadSubmit`/`fileWriteSubmit`). Первая сборка `zig build browser` упала: `std.Io.Threaded`'s `RandomFile` тянет `posix.system.getrandom`, отсутствующий на freestanding — ровно тот класс ошибки, что уже документирован в разделе "Zig-тулчейн" выше, но на этот раз ловушкой оказался НЕ отсутствующий `else`, а его ПОЛНОЕ отсутствие в четырёх местах, где вызов вообще ничем не гейтился. Исправлено — те же четыре метода получили `if (comptime builtin.target.os.tag == .freestanding) { return trivially } else { real Threaded-based impl }` — на wasm `outstanding`/`items` всегда 0, потому что ни одна async-задача там никогда не отправляется.

### Тесты

Новый `runner.zig`-тест `"runner runs an independent process to completion while another awaits async фс.прочитать"` — детерминированное (без сна/таймаутов) доказательство настоящей конкурентности: процесс-читатель уходит в фоновое чтение и суспендится на `await_async`, НЕЗАВИСИМЫЙ процесс-быстрый успевает полностью отработать и доставить сообщение родителю ДО того, как читатель получает результат — порядок гарантирован структурой прохода планировщика, не таймингом. Живьём проверено через `zig build run`-бинарник: `быстрый-готов | прочитано` — независимый процесс действительно продвигается, пока другой ждёт I/O, никакого блокирования VM в целом. Существующие `фс.прочитать`/`фс.записать` тесты (успех/ошибка/отсутствующий файл/gzip-конвейер) остаются зелёными без изменений — async-путь transparently заменяет синхронный для тех же программ. `zig build test`/`conformance`/`lsp`/`browser` — все зелёные.

### Не перенесено в этом срезе

`сеть.http_запрос`/`сеть.подключиться`/`бд.*`/стриминговые `Файл.прочитать*`/`Соединение.получить*` остаются полностью синхронными — тот же submit+await_async паттерн переносится на них по мере необходимости, задел (`AsyncPayload`/`AsyncQueue`/диспетчер) уже общий. `gc_pin`/`gc_unpin` (нужны только для уже открытых стриминговых хендлов, не для одноразовых фс.прочитать/записать) сознательно не перенесены — этот срез их не требует.

## Неблокирующий I/O — второй срез: сеть.подключиться + сеть.http_запрос

Продолжение предыдущего среза (`фс.прочитать`/`фс.записать`) — тот же submit+await_async паттерн, распространённый на два самых частых источника РЕАЛЬНО долгого блокирования (DNS+TCP handshake, полный HTTP round-trip). Оба — одноразовые операции (не трогают уже открытый хендл), поэтому `gc_pin` по-прежнему не нужен — тот же аргумент, что у `фс.*`.

- **`сеть.подключиться`**: `netConnectSubmit` клонирует host на `page_allocator`, воркер делает `IpAddress.resolve`+`.connect`, возвращает голый `std.Io.net.Stream` (POD, без GC-указателей) через `AsyncPayload.net_connect`; `buildAsyncResultValue` на главном потоке заворачивает его в `heap.createConnection(...)` — ТА ЖЕ операция, что раньше делал синхронный `netConnect`, просто теперь после доставки, а не сразу. Валидация порта (0..65535) — синхронная, без похода в воркер-пул; результат всё равно кладётся В `process.async_results` напрямую (не на `self.stack`), потому что компилятор ВСЕГДА эмитит `await_async` следом за submit — иначе `await_async` ждал бы результат, которого никто не положит.
- **`сеть.http_запрос`**: самый крупный перенос в этом срезе — вся синхронная логика (`std.http.Client`, отправка тела, чтение+декомпрессия ответа) перенесена В ВОРКЕР почти без изменений структуры, единственная правка — каждый `self.allocator`/`self.heap.createXxx` вызов заменён на `std.heap.page_allocator`/голую структуру (`HttpHeaderPair`/`HttpRequestResult`) — GC-объекты (заголовки-пары, тело-строка, кортеж-результат) строятся ТОЛЬКО при доставке (`buildHttpAggregateResult`, главный поток), воркер их не видит вообще. `Соответствие(Строка, Строка)` заголовков-аргумент клонируется в `[]HttpHeaderPair` на `page_allocator` ДО спавна потока (та же причина, что у path/content — Map/Value байты не потокобезопасны для конкурентного чтения после возврата из builtin'а).

### Побочная находка: усечённый слайс — не то же самое, что allocator.free

При клонировании заголовков в `httpRequestSubmit` часть записей мапы может быть пропущена (нестроковый ключ/значение) — исходный код просто фильтровал их `continue`'ом. Первая версия передавала воркеру `owned_headers[0..header_count]` (под-слайс более длинной `page_allocator`-аллокации) — воркер потом делает `page_allocator.free(job.headers)` с ЭТОЙ укороченной длиной, а не исходной, с которой был выделен буфер. `page_allocator.free` требует ТОЧНОГО совпадения указателя И длины с тем, что вернул `alloc` — рассинхронизация длины поймана до попадания в рантайм (не через краш, через код-ревью собственного диффа перед сборкой), исправлено через `allocator.realloc(owned_headers, header_count)` (гарантированно успешное сужение) вместо простого среза.

### Тесты

Живьём проверено через `zig build run`-бинарник на РЕАЛЬНОМ сетевом хосте (`http://example.com/`): `сеть.http_запрос` возвращает `Успех`; конкурентный вариант (один процесс делает настоящий HTTP-запрос, другой — нет) даёт `быстрый-готов | http-готово` — независимый процесс не блокируется реальным сетевым round-trip'ом. `zig build test`/`conformance`/`lsp`/`browser` — все зелёные, существующие `сеть.*` unit/e2e тесты не изменены и остаются зелёными без правок (async-путь transparently заменяет синхронный для тех же программ).

### Не перенесено

`бд.*` (SQLite — вероятно низкий приоритет, локальный диск, обычно быстро) и все стриминговые операции над уже открытым хендлом (`Соединение.получить*/отправить`, `Файл.прочитать*/записать`, `Соединение_БД.выполнить/запрос`) — последние требуют `gc_pin`/`gc_unpin` (объект должен пережить полёт, даже если единственная panos-ссылка на него исчезнет), которых в Zig-версии пока нет вообще.

## gc_pin/gc_unpin + третий срез: Соединение.получить() (стриминговый хендл)

Первое использование `gc_pin` в Zig-версии — до этого момента его вообще не существовало (все перенесённые ранее builtin'ы были одноразовыми: открыть/прочитать/записать/подключиться, без уже-открытого хендла, который могли бы держать живым дольше одного вызова).

### gc.zig: pinned — как protect_stack у Odin, только по значению

`Heap.pinned: std.ArrayList(value.Value)` — долгоживущая, порядконезависимая защита (в отличие от короткого LIFO protect/unprotect в пределах одного вызова). `pin`/`unpin` — добавление/поиск-и-удаление ПО ЗНАЧЕНИЮ (`Value.eql`), не по позиции в стеке — так что произвольно чередующиеся короткие pin'ы от ДРУГИХ вызовов не мешают друг другу. И `Vm.collect()`, и вспомогательный `Heap.collect(roots)` (используется только в юнит-тестах `gc.zig`) теперь помечают `heap.pinned.items` перед sweep. Новый тест `"heap keeps a pinned object alive with zero other roots, sweeps it after unpin"` — прямая проверка: объект без единого другого корня переживает `collect()` только благодаря pin, и подметается сразу после unpin.

### Соединение.получить(): in_flight/close_requested — та же гонка, что документирована у Odin

`value.Connection` получил `in_flight: bool`/`close_requested: bool`. `connectionReadSubmit`:
1. `!is_open` или `in_flight` — синхронная ошибка (`"уже закрыто"`/`"уже используется другой операцией"`, тот же busy-error, что у Odin's `test_async_stream_concurrent_read_is_busy_error`), положенная СРАЗУ в `process.async_results` (не на `self.stack`) — та же причина, что у валидации порта в `сеть.подключиться`: `await_async` всегда следует за submit'ом.
2. Иначе: `pending` (недочитанный остаток от `.получить_строку()`) сливается в переданный воркеру буфер, `in_flight = true`, `heap.pin(.{.connection = connection})`, и ТОЛЬКО КОПИЯ `stream` (голая POD-структура) уходит в воркер — воркер никогда не видит указатель на `Connection`, только его копию как opaque-идентификатор для доставки.
3. `deliverAsyncResult` теперь ДВУХфазный: сначала (`finishConnectionFlight`, БЕЗУСЛОВНО, даже если целевой процесс уже мёртв) снимает `in_flight`/`unpin`, и если `.закрыть()` был вызван во время полёта — только ТЕПЕРЬ реально закрывает fd; затем (если процесс жив) строит и доставляет `Value`.
4. `.закрыть()` во время `in_flight` не трогает fd — только `close_requested = true` + `is_open = false` СРАЗУ (видимое для panos-кода поведение "уже закрыто" не ждёт завершения полёта, только настоящий syscall откладывается).

### Тесты

Живьём (не автоматизированный тест, а прямая проверка через `zig build run`): реальный TCP через локальный echo (`nc`) — `Соединение.получить()` читает `hello-from-nc`. Конкурентность — Python-сервер, отвечающий с искусственной задержкой 1.5с, против независимого процесса без I/O: `быстрый-готов | tcp-готово` — блокирующее на 1.5с чтение не блокирует остальной VM. `zig build test`/`conformance`/`lsp`/`browser` — все зелёные, существующие `Соединение.*`/`сеть.*` тесты не менялись.

### Не перенесено

`Соединение.отправить()`, `Файл.прочитать*/записать` (стриминговые), `Соединение_БД.выполнить/запрос`, `бд.открыть` — тот же паттерн (submit + await_async, + gc_pin для тех, что держат хендл) применяется по мере необходимости, инфраструктура (`AsyncQueue`/`pin`/`unpin`/`finishConnectionFlight`-shaped delivery) уже общая.

## Четвёртый срез: Соединение.отправить() + Файл.прочитать*/записать

Механическое повторение уже установленного паттерна (submit + await_async + in_flight-гейт + gc_pin) на оставшиеся стриминговые builtin'ы над уже открытым хендлом.

- **`Соединение.отправить()`**: `connection_write` AsyncPayload (`bytes_written`/`err_message`), `submitConnectionWrite` — воркер получает копию content (page_allocator), делает `writeAll`+`flush` через копию `stream`. `deliverAsyncResult` теперь диспетчерит И `connection_read`, И `connection_write` в один и тот же `finishConnectionFlight` (снятие in_flight/unpin/отложенный close — общий для чтения и записи, потому что оба держат ОДИН и тот же `in_flight`-флаг на `Connection`).
- **`Файл.прочитать()`/`.прочитать_строку()`/`.записать()`**: `value.FileHandle` получил свой `in_flight` (та же гонка на `offset`, что и у `Connection.in_flight` — конкурентные submit'ы иначе снимали бы стартовый offset ДО того, как первый успевал его обновить). Одна общая `submitFileHandleRead` (флаг `want_line` выбирает whole-remainder или posize-newline-splitting логику — идентична прежней синхронной паре) + `submitFileHandleWrite` (та же positional-overwrite арифметика, что раньше, просто на `page_allocator`). Доставка (`finishFileHandleFlight`) применяет `new_offset`, вычисленный ВОРКЕРОМ, к хендлу — единственное состояние, которое реально нужно защищать через in_flight (никакого живого OS-хендла нет вообще — `Файл` переоткрывается по пути каждый раз, см. `value.zig`).

### Тесты

Живьём: `Файл.прочитать_строку()`, вызванный дважды подряд (через suspend/resume между двумя вызовами) — `первая строка|вторая строка`, offset корректно продвигается через асинхронную границу. `Соединение.отправить()`+`.получить()` — реальный TCP echo (`hi` → `echo:hi`). `zig build test`/`conformance`/`lsp`/`browser` — все зелёные, ни один существующий тест не менялся.

### Итог по неблокирующему I/O (Zig-порт)

Перенесены: `фс.прочитать/записать`, `сеть.подключиться`, `сеть.http_запрос`, `Соединение.получить/получить_строку(частично — только .получить конвертирован, .получить_строку остаётся синхронным)/отправить/закрыть`, `Файл.прочитать/прочитать_строку/записать`. Не перенесены (сознательно, отдельные будущие срезы): `Соединение.получить_строку()` (частичное чтение с carry-over в `pending` — тот же паттерн, но требует аккуратности с уже слитым `pending` между несколькими async-вызовами), `бд.открыть/выполнить/запрос` (SQLite — низкий приоритет, локальный диск).

## Пятый срез: Соединение.получить_строку() + бд.* (SQLite) — все sync-builtin'ы перенесены

Последние два куска из списка "не перенесено" в предыдущем разделе.

### Соединение.получить_строку()

Сложнее прочих потоковых операций — исходная реализация делает НЕСКОЛЬКО блокирующих чтений подряд (цикл: искать `\n` в `pending`, если нет — читать ещё). Весь цикл целиком переехал в воркер (`submitConnectionReadLine`), с одной тонкостью: `new_pending` (что осталось в буфере накопления) ВСЕГДА присутствует в `AsyncPayload` — даже при ошибке чтения, чтобы повторный `.получить_строку()` после временного сбоя не потерял уже накопленные, но ещё не сложившиеся в строку байты. `finishConnectionReadLineFlight` (общая lifecycle-точка) копирует `new_pending` обратно в `connection.pending` ДО построения итогового `Value` — что бы ни случилось с доставкой (мёртвый процесс), буфер не теряется.

### бд.открыть/выполнить/запрос

`value.SqlConnection` получил `in_flight` (тот же мотив, что у `Connection`/`FileHandle` — serialize-per-connection, не полагаясь на встроенный SQLite threading mode). `бд.открыть` — одноразовая операция (как `сеть.подключиться`), без `gc_pin`. `.выполнить()`/`.запрос()` — параметры (`Массив(Строка)`) валидируются и клонируются на `page_allocator` ДО спавна (`cloneSqlParams`, тот же приём, что у HTTP-заголовков) — невалидный (нестроковый) параметр отклоняется синхронно, не доходя до воркера. Воркер-версия подготовки запроса (`sqlPrepareWorker`) — копия `Vm.sqlPrepare`, но без доступа к `Vm` (голый `page_allocator`). `.запрос()` возвращает позиционные (не именованные по колонкам сразу) `column_names`/`rows: [][]?[]u8` — `Соответствие(Строка,Строка)` на каждую строку строится ТОЛЬКО при доставке (`buildAsyncResultValue`), тем же способом, что раньше делал `sqlReadRow` (NULL-колонка пропускается, BLOB — ошибка на весь запрос).

### Тесты

Живьём: полная цепочка `бд.открыть` → `CREATE TABLE` → `INSERT` → `SELECT` через реальный SQLite-файл, конкурентно с независимым процессом — `быстрый-готов | sql-готово:панос`. `Соединение.получить_строку()`, вызванный дважды подряд через suspend/resume — `line-one|line-two` (сервер шлёт вторую строку с задержкой 0.3с между двумя `send()`, доказывая, что каждый вызов реально ждёт СВОИ данные, не читает всё разом). `zig build test`/`conformance`/`lsp`/`browser` — все зелёные.

### Итог: все существовавшие блокирующие I/O-builtin'ы перенесены на неблокирующую схему

`фс.прочитать/записать`, `Файл.прочитать/прочитать_строку/записать`, `сеть.подключиться`, `Соединение.получить/получить_строку/отправить`, `сеть.http_запрос`, `бд.открыть/выполнить/запрос` — единообразный submit+await_async(+in_flight-гейт+gc_pin для держащих хендл) паттерн по всему файлу. Единственные builtin'ы, намеренно оставшиеся синхронными — `.закрыть()` на всех трёх типах хендлов (мгновенная локальная операция, `Соединение.закрыть()` уже учитывает in-flight гонку через `close_requested`) и всё, что помечено `native_only`/недоступно на freestanding (не имеет смысла асинхронизировать то, что и так не существует в браузере).

## HTTP-сервер (сеть.http_сервер_слушать) — впервые в Zig-версии, разблокировано планировщиком

Ранее отмечено как заблокированное ("HTTP server still not started, blocked on scheduler") — теперь, когда есть настоящий round-robin планировщик + submit/await_async инфраструктура, перенос стал прямолинейным, БЕЗ Odin-овской сложности (там `http.serve` блокирует поток НАВСЕГДА, требуя выделенный `thread.create_and_start` на слушатель — здесь `.принять_запрос()` просто ещё один async-builtin поверх уже существующего воркер-пула).

### Новые opaque-типы: Слушатель, Запрос

`value.Listener` (`server: std.Io.net.Server`) и `value.HttpRequestHandle` (`stream`, уже распарсенные `method`/`path`, `responded: bool`) — тот же принцип, что `Файл`/`Соединение`. Ключевое структурное отличие от `Connection`/`FileHandle`/`SqlConnection`: у `Listener` НЕТ `in_flight`/`gc_pin`-single-flight гейта — множественные ОДНОВРЕМЕННЫЕ `.принять_запрос()` (из разных процессов) это и есть смысл сервера, не гонка, которую надо предотвращать. `Heap.pin`/`unpin` уже поддерживают несколько параллельных pin'ов одного значения (список, не единственный флаг) — pin ставится на каждый accept в полёте отдельно, unpin снимает по одному при каждой доставке.

### сеть.http_сервер_слушать — sync; .принять_запрос() — async; .ответить() — sync

`bind`+`listen` — быстрый локальный syscall, остаётся синхронным (как DNS+connect у `сеть.подключиться` НЕ разделены). `.принять_запрос()` — воркер копирует `std.Io.net.Server` ПО ЗНАЧЕНИЮ (`accept()` только читает поля, не мутирует — независимые копии, зовущие `accept()` параллельно на одном слушающем сокете, безопасны, обычное POSIX-поведение), делает `accept()` + `std.http.Server.receiveHead()` (тот же `std.http`, что уже используется клиентской стороной `сеть.http_запрос`) — извлекает метод/путь как плоские данные, стрим остаётся живым для последующего `.ответить()`. `.ответить(статус, тип, тело)` — синхронный (как `.закрыть()`) — вручную форматирует HTTP-ответ (без `std.http.Server.Request.respond()`, чтобы не тащить состояние `std.http.Server` через async-границу) и пишет через свежий `stream.writer()`; ошибка записи проглатывается (`Запрос.ответить()` возвращает голый `Пусто`, не `Результат` — клиент уже отвалился, обрабатывать нечего). Одно соединение — один запрос (без keep-alive), стрим закрывается сразу после ответа.

### Побочное: диск кончился в процессе (`.zig-cache` вырос до 24ГБ)

Компиляция упала с `error: failed to write: NoSpaceLeft` — не связано с кодом, `.zig-cache` за сессию раздулся до 24ГБ (много инкрементальных пересборок). Удалён (`rm -rf .zig-cache`, полностью регенерируемый кэш) — свободно 24ГБ, пересборка с нуля прошла чисто.

### Тесты

Живьём через `curl`: `GET /` → `привет от паноса`, `GET /missing` → `не найдено` (выбор по `запрос.путь()` в самом panos-коде — `Запрос` не содержит встроенного роутера, как и планировалось для v1). `zig build test`/`conformance`/`lsp`/`browser` — все зелёные, автоматизированных тестов на HTTP-сервер пока не добавлено (требует реального сокета в `runner.zig`-стиле, как у `http_router_serve_fixture` в Odin-версии — оставлено на следующий срез).

### Сознательно не перенесено в этом срезе

Тело запроса (`Запрос` не читает `Content-Length`/тело — только метод+путь, как минимальный роутинг-контракт), заголовки запроса (нет `.заголовок(имя)`), keep-alive/несколько запросов на соединение, вебсокеты (`std.http.Server.WebSocket` уже есть в std, но не подключен). Настоящая ПАРАЛЛЕЛЬНАЯ обработка нескольких запросов требует от panos-кода спавнить обработчик отдельным процессом ПЕРЕД повторным accept (`запусти обработчик(...)`, затем сразу `крутить(слушатель)`) — сам VM это уже полностью поддерживает, это вопрос паттерна в пользовательском коде, не инфраструктуры.

## HTTP-сервер: автоматизированный тест на реальном сокете

Закрывает пробел, отмеченный в предыдущем разделе ("автоматизированных тестов на HTTP-сервер пока не добавлено").

`runner.zig`: `tryHttpGetOnce` — сырой (без `std.http.Client`) GET через `std.Io.net` напрямую (connect+write запрос текстом+читать до EOF), возвращает `null` при отказе соединения. Тест `"runner serves a real HTTP request through сеть.http_сервер_слушать"` — запускает `runSource` (панос-сервер: слушать→принять_запрос→ответить) в ОТДЕЛЬНОМ `std.Thread` (он блокируется на реальном accept), сам тестовый поток опрашивает сервер (`tryHttpGetOnce` + `std.Io.sleep(10мс)` между попытками, до 200 раз — не блокирующий `Thread.sleep` — Zig 0.16 убрал его из `std.Thread`, есть только `std.Io.sleep(io, duration, clock)`) вместо фиксированной задержки на старт: accept происходит на воркер-потоке ТОЛЬКО когда планировщик реально до него доходит, фиксированный `sleep` перед первой попыткой был бы либо избыточно долгим, либо ненадёжным. `.awake`-часы (monotonic-с-момента-загрузки) — `Clock` enum в Zig 0.16 не содержит `.monotonic` под этим именем.

Проверено 3 прогона подряд без флейков (accept+respond+возврат `Execution` синхронизированы через `thread.join()`). `zig build test`/`conformance`/`lsp`/`browser` — все зелёные.

## HTTP-сервер: Запрос.заголовок(имя) -> Опция(Строка)

Закрывает второй пробел из "сознательно не перенесено" — доступ к заголовкам входящего запроса.

`value.HttpRequestHandle` получил `headers: []HttpHeaderEntry` (новый маленький тип в `value.zig`, `{name, value}` — обе строки `Vm.allocator`-owned копии, освобождаются в `gc.zig`'s `destroy` вместе с `method`/`path`). Воркер (`submitHttpAccept`) собирает их через `request.iterateHeaders()` (тот же `std.http.HeaderIterator`, что уже используется клиентской стороной `сеть.http_запрос`) — тем же `HttpHeaderPair`-типом, что уже существовал для клиентских заголовков, переиспользован как есть. `Запрос.заголовок(имя)` — линейный поиск без учёта регистра (`std.ascii.eqlIgnoreCase`, HTTP-заголовки регистронезависимы по стандарту), возвращает `Опция(Строка)` через уже существующий `makeOptionValue`-хелпер (тот же, что `ос.окружение`/`синтаксис.аргумент_аннотации`).

### Тесты

Живьём через `curl -H "X-Test: ..."` — заголовок доходит до panos-кода и обратно в ответ. Новый `runner.zig`-тест `"runner reads a custom request header through Запрос.заголовок"` — та же реальная-сокет+поток инфраструктура, что предыдущий HTTP-тест, переиспользована через параметризованный `tryHttpGetOnceWithHeader` (добавлен опциональный `extra_header` параметр к уже существующему `tryHttpGetOnce`, старый вызов не изменился). 3 прогона подряд без флейков. `zig build test`/`conformance`/`lsp`/`browser` — все зелёные.

### Итог по HTTP-серверу (v1)

`сеть.http_сервер_слушать`/`Слушатель.принять_запрос`/`Запрос.метод/путь/заголовок/ответить` — полный минимальный контракт для написания HTTP-обработчиков на panos, с реальными автоматизированными тестами (не только ручной проверкой). Осталось сознательно не тронутым: тело запроса, keep-alive, вебсокеты, встроенный роутер (панос-код сам решает через `выбор запрос.путь()`, как показано в тестах/примерах) — все явно вне рамок этого первого среза.

## T037 (doc-only), T042 (native integration tests), T047 (3 new LSP features)

Ответ на "выполни всё от 037 до 048" — T038/039/040/041 уже были сделаны в предыдущих срезах (только не отмечены в tasks.md), T037 обновлён как чисто документационная правка (функциональность уже полная). Реально новая работа в этом срезе:

### T042 — tests/integration/native/

4 отдельных `.ps`-фикстуры (не inline-строки — можно запускать напрямую через CLI): `file_roundtrip.ps`, `sqlite_roundtrip.ps`, `ffi_libc.ps`, `http_client_error.ps` (единственный сетевой случай — управляемый отказ на закрытый локальный порт, никакого исходящего интернета). Новый `tests/integration/native_test.zig` (`@embedFile` каждой фикстуры + `runner.runSource` + точное сравнение результата), подключён и в `zig build test`, и в `zig build conformance` — нужна та же sqlite/libffi-линковка, что у `core_tests`, на ОТДЕЛЬНОМ модуле (не общий `core_module`, который также импортирует wasm `browser`).

### T047 — три новых LSP-метода

`textDocument/selectionRange` — грубая, но честная 2-3-уровневая цепочка (innermost — span выражения под курсором через `findExpressionAt`+`ast.exprSpan`, затем ближайший top-level `DocumentSymbol`, затем весь файл) — НЕ полная AST-statement-вложенность (в этом AST нет родительских указателей для обхода вложенности блоков/операторов). `textDocument/codeLens` — один lens на функцию с числом ссылок (переиспользует тот же скан `expr_symbols`, что и `references`). `workspace/symbol` — регистронезависимый подстрочный поиск по ВСЕМ открытым документам через `DocumentStore.documents` (не только активный). Capabilities JSON обновлён (`selectionRangeProvider`/`codeLensProvider`/`workspaceSymbolProvider`). Новые тесты в `main.zig`'s существующем LSP-транскрипт-тесте. `zig build test`/`conformance`/`lsp`/`browser` — все зелёные, 3 повтора без флейков.

Не сделано (осознанно, за рамками этого среза): `semanticTokens/full` (отдельная фича — нужна классификация токенов + legend, не маленькое добавление) и КРОСС-ДОКУМЕНТНЫЕ `definition`/`references` (сегодняшние версии ищут только в ОДНОМ анализируемом документе — реальная кросс-документная поддержка требует построения per-workspace индекса символов по `импорт`-рёбрам, которого у этого LSP нет вообще).

## T043 (MIR→WASM AOT) — начало порта

Пользователь подтвердил: начинать порт сейчас же, вертикальными срезами, как T037-041. Это отдельная, большая инициатива (~9000 строк только MIR+wasm-часть в Odin, без учёта рантайм-обёрток) — реалистично много сессий, не один заход.

### Что сделано в этом срезе

- **`zig/core/mir.zig`** — полная модель данных MIR (Phase 1 + объявленный, но пока не лоурящийся Phase 2 — та же философия, что у Odin: `Instruction`/`Terminator` исчерпывающие с самого начала, чтобы validate/print/emit не дописывались по одному case на каждую следующую фазу). `ValueId`/`LocalId`/`BlockId`/`FunctionId` — голые index-enum'ы (`enum(u32) { _ }`), НЕ указатели — то же обоснование, что у Odin (append в growable array может инвалидировать указатель). `Instruction`/`Terminator`/`Place` — `union(enum)`, тем же стилем, что `bytecode.Instruction`. Резолверные/тайпчекерные типы (`symbols.SymbolId`, `types.TypeId`, `source.Span`) переиспользуются напрямую, MIR ничего не пересчитывает.
- **`zig/core/mir_builder.zig`** — `Builder`, тонкая обёртка над ОДНОЙ функцией модуля. Критичный инвариант, перенесённый дословно: функция/блок адресуются ИНДЕКСОМ (`function_id`/`current_block_id`), не сырым указателем — `currentFunction()` каждый раз заново разыменовывает `module.functions.items[...]`, потому что `append` может реаллоцировать backing-буфер. `emit`/`terminate` паникуют при попытке дописать в уже завершённый terminator'ом блок — тот же defensive rubeж, что у Odin.
- **`zig/core/mir_cfg.zig`** — `computeCfgInfo`, итеративный (без рекурсии — глубокий CFG на длинной цепочке если/иначе не должен рисковать стеком компилятора) post-order DFS по terminator'ам блоков, вычисляет predecessors/reachable/reverse_postorder НА ЛЕТУ, не кэшируется на `Function` (та же причина, что и у builder'а — стал бы рассинхронизирован с реальным графом после любой мутации terminator'а).

### Тесты

6 новых Zig-тестов (2 на файл) — включая diamond-если/иначе CFG (join-блок с двумя predecessors), обнаружение недостижимого блока, и terminated-block инвариант билдера. `zig build test`/`conformance`/`lsp`/`browser` — все зелёные.

### Следующие срезы (не начаты)

`mir_lowering.zig` (AST→MIR, самая большая семантическая часть — читает ТЕ ЖЕ resolver/type-checker side-таблицы, что уже читает `compiler.zig`, просто эмитит MIR вместо байткода), `mir_validate.zig`, затем `wasm_stackify.zig`/`wasm_emit.zig`/`wasm_module.zig` (собственно MIR→WASM бинарник — то, что нужно для `panos build --target=wasm`, T048). Odin's MIR→bytecode backend (`mir_bytecode.odin`) — НЕ в скоупе порта: это equivalence-harness для самой Odin-реализации, а не то, что нужно ЭТОЙ миграции (AST→bytecode уже есть и работает через `compiler.zig`).

## T043 (MIR→WASM AOT) — mir_lowering.zig (AST→MIR)

Продолжение MIR-порта. `zig/core/mir_lowering.zig` — самая большая семантическая часть (~2000 строк в Odin), сужена ЕЩЁ дальше собственной "Фазы 1" Odin: числа/булевы/строки-литералы, локали, унарные/бинарные операторы (включая short-circuit `и`/`или` через тот же non-SSA "merge через temp-локаль" приём, что `если`/`иначе` использует для значения ветки), `если`/`иначе`, `пока`+`прервать`/`продолжить`, обычные вызовы функций (по идентификатору ИЛИ по значению — общий `Call_Value_Instr`-fallback), `возврат`. Всё остальное (`выбор`/ADT, замыкания, интерфейсы, акторы, дженерики, sugar Сравниваемое/Арифметика, `для`, деструктуризация, builtin'ы, методы, `внешний`) — `@panic` через `unsupported()`, тем же принципом, что Odin's `lower_unsupported`: этот пайплайн пока не достижим из обычной компиляции, явный крах лучше тихо неправильного MIR.

### Три реальных бага, найденных тестами (не чтением порта)

1. `unreachable`, ДОСТИЖИМЫЙ в `lowerBlock` при `want_value == false` и все statement'ы `.continues` — цикл просто заканчивался без явного `return`, попадая на `unreachable` в конце функции. Исправлено — конец функции теперь `return continuesWith(mir.invalid_value)`.
2. Утечка: слайс аргументов `call_value`-инструкции нигде не освобождался (`mir.zig` вообще не имел no per-instruction free ни для одного instruction kind). Вместо ручного трекинга каждого instruction-варианта с variable-length полем — у `mir.Module` теперь своя арена (`Module.arena`), тем же принципом, что `compiler.zig`'s `CompileResult.arena` — вся память таких слайсов освобождается ОДНИМ блоком при `Module.deinit`.
3. Баг в собственном тесте, не в порте: `пока условие цикл ... конец` требует ключевое слово `цикл` (легко забыть, придя из языков, где `while` не нуждается в разделителе) — тест содержал невалидный синтаксис, парсер тихо восстановился, а `checked.diagnostics` (единственное, что тест проверял) остался пустым — поймано только добавлением проверки `parsed.diagnostics`, которой раньше не было. Теперь стандартный паттерн для будущих тестов на lowering.

Также: взаимно-рекурсивные функции lowering'а потребовали явных `anyerror!` (Zig не разрешает вывод error-set через цикл зависимости из 3+ функций).

### Тесты

2 новых теста: `факториал` → если/иначе даёт корректный 4-блочный CFG, все блоки reachable; `пока`-цикл, чьё тело всегда `возврат`ается → back-edge jump НЕ эмитится (проверено напрямую по terminator'ам блоков). `zig build test`/`conformance`/`lsp`/`browser` — все зелёные, 3 повтора без флейков.

### Не начато

`mir_validate.zig`, затем сама цель T043 — `wasm_stackify.zig`/`wasm_emit.zig`/`wasm_module.zig` (MIR→WASM бинарник).

## T043 (MIR→WASM AOT) — wasm_stackify/wasm_module/wasm_emit: реальный работающий бинарник

Завершение основной цели T043 для Phase-1a подмножества — впервые в этой сессии эмитируется, записывается на диск и РЕАЛЬНО ИСПОЛНЯЕТСЯ настоящий `.wasm`-бинарник (не просто структурно валиден "на бумаге").

### wasm_stackify.zig — dominance-based relooper queries

Порт `core/wasm_stackify.odin`: `isLoopHeader` (back-edge через reverse-postorder — единственный вид "назад"-ребра, который в принципе может возникнуть, раз MIR всегда reducible), `identifyLoopBodyAndExit` (какая из двух веток Branch у loop-header — тело, какая — выход, через `canReach`), `computeIdom` (Cooper/Harvey/Kennedy iterative dominance), `findMerge` (единственный блок M с `idom[M]==branch_block` — то же обоснование, что в Odin-доккомменте: обычная "больше одного predecessor" эвристика путает "слияние ЭТОГО если/иначе" с точкой, разделяемой с внешним кодом, напр. exit цикла).

### wasm_module.zig — бинарные примитивы

LEB128 (uleb/sleb128), f64 little-endian, секции (`writeSection`). Число/Целое → f64, Булево → i32 — та же конвенция, что Odin.

### wasm_emit.zig — сама эмиссия

`processFrom` — дословный порт `process_from` (структурный драйвер: loop-header оборачивается в `loop`+`if` с cond ВНУТРИ loop, потому что `пока cond цикл` должен пересчитывать cond КАЖДУЮ итерацию, а не один раз до входа — это Odin's собственная находка через дифференциальное тестирование, перенесена как есть). Два отступления от Odin, оба задокументированы:
- `mir_validate.zig` не портирован — вместо переиспользования готового `use_count` оттуда, `computeUseCount` в `wasm_emit.zig` считает использования САМ (по ограниченному Phase-1a набору инструкций) для drop-if-unused (WASM-валидатор не терпит несбалансированной высоты стека на границах блоков, а MIR легитимно содержит значения с нулём использований — напр. 0.0-заглушка `пока`-как-выражения).
- `Function_Ref_Instr` не кладётся на WASM-стек вообще (нет таблицы функций/closures в этом срезе) — записывается в `value_to_function`-карту, `call_value` находит по ней статический callee и эмитит прямой `call`. Оба паттерна ВСЕГДА идут смежной парой в `mir_lowering.zig`, поэтому это безопасное сужение, не хак.

### Реальная проверка — не только структурная

`emitModule` на рекурсивной `факториал` функции → записан в `.wasm`-файл → запущен через настоящий `wasmtime run --invoke` (subprocess, `std.process.run`, абсолютный путь к бинарнику — `argv[0]` без `expand_arg0=.expand` НЕ ищется в `$PATH`; тест грациозно `SkipZigTest`, если wasmtime не установлен) — `факториал(5) == 120`, подтверждено и в автоматическом тесте, и вручную через отдельный `сумма_до`-пример (там же вручную подтверждена ГРАНИЦА текущего среза: `итог = итог + i` — присваивание — падает с понятным `@panic`, ровно как и задокументировано в `mir_lowering.zig`, значит НАСТОЯЩИЙ итерирующий цикл пока продемонстрировать нельзя, только структуру пустого цикла).

### Тесты

`wasm_module_test`: LEB128/f64 round-trip. `wasm_stackify_test`: `findMerge` на diamond-если/иначе, `isLoopHeader`+`identifyLoopBodyAndExit` на простом цикле. `wasm_emit_test`: полный pipeline лексер→парсер→резолвер→тайпчекер→MIR→WASM→wasmtime, реальный результат `120`. `zig build test`/`conformance`/`lsp`/`browser` — все зелёные, 3 повтора без флейков.

### Итог по T043

Основная цель ("MIR, lowering, validation, stackification and binary emission") выполнена для Phase-1a: числа/булевы, локали, арифметика/сравнения/унарные операторы (без модуло/побитовых/сдвигов — нужна i32/i64-конверсия), если/иначе, пока (без присваивания — реальные итерирующие циклы всё ещё недоступны), прямые вызовы функций, возврат. НЕ сделано: `mir_validate.zig` (не блокер сейчас — `mir_lowering.zig` сама гарантирует нужные инварианты — но настоящий пробел в защите от БУДУЩИХ багов лоуринга), присваивание/мутация, `zig/wasm_runtime/` object-table рантайм для агрегатов/массивов/строк/замыканий/интерфейсов (Фаза 2), `panos build --target=wasm` CLI-обвязка (T048).

## T043 (MIR→WASM AOT) — присваивание локалей, первый реальный итерирующий цикл

Закрывает главный пробел из предыдущего среза. `zig/core/mir_lowering.zig`'s `lowerBinary` — `.assign` больше не `unsupported()`, вызывает новую `lowerAssign` — дословный порт `core/mir_lowering.odin`'s `lower_assign`/`lower_place`, но ещё сильнее сужен под Phase-1a: цель присваивания поддержана ТОЛЬКО как `Ident_Expr`, резолвящийся в `ctx.symbol_to_local` (обычная локальная переменная) — `unsupported("присваивание не-локали (Фаза 3+)")` для всего остального, потому что структур/массивов эта фаза лоуринга вообще не эмитит, так что `Property_Expr`/`Index_Expr`-цели были бы недостижимы в любом случае. Присваивание, как и в Odin и в существующем bytecode-компиляторе, НЕ производит значения (`y = (x = 1)` не поддержано что там, что тут) — эмитит `store_local` и возвращает `mir.invalid_value`; на корректно типизированном коде эта граница никогда не наблюдаема, потому что тайпчекер требует единый тип у обеих ветвей если/иначе-как-значения ДО того, как лоуринг вообще запускается.

### Тесты

`mir_lowering.zig`: новый тест на аккумулирующий `пока`-цикл (`итог = итог + i`, `i = i + 1`) — проверяет, что тело цикла теперь эмитит back-edge `jump` обратно на header (в отличие от предыдущего теста, где тело всегда `возврат`ается и back-edge отсутствует). `wasm_emit.zig`: новый end-to-end тест через настоящий `wasmtime` — `сумма_до(10) == 45` (1+2+...+9, т.к. `i < предел`) — первое в этой миграции реальное исполнение итерирующего цикла с мутацией состояния, не просто структура пустого цикла. `zig build test`/`conformance`/`lsp`/`browser` — все зелёные, 3 повтора `test` без флейков.

### Что всё ещё не сделано в T043

`mir_validate.zig`, присваивание в структуры/массивы (заблокировано на Phase-2 object-table рантайме — те типы вообще не лоурятся сейчас), `zig/wasm_runtime/` (агрегаты/массивы/строки/замыкания/интерфейсы), `panos build --target=wasm` CLI-обвязка (T048).

## T043 (MIR→WASM AOT) — mir_validate.zig: структурный верификатор MIR

Закрывает последний оставшийся пробел основной цели T043. `zig/core/mir_validate.zig` — дословный порт `core/mir_validate.odin`: прогоняется ПОСЛЕ лоуринга каждой функции, ничего не мутирует, только читает. Проверяет: entry-блок задан и в диапазоне; каждый terminator корректен (Jump/Branch на существующие блоки, Return согласован с типом результата функции — есть значение только когда результат не Пусто); каждая инструкция пишет/читает Value_Id в диапазоне; Load_Local/Store_Local ссылаются на существующую локаль; Call — на существующую функцию модуля с верным числом аргументов; и главное — **single-use инвариант**: каждый Value_Id используется как операнд НЕ БОЛЕЕ одного раза за всю функцию (на этом инварианте держится весь `wasm_emit.zig`'s stack-machine replay — без него понадобился бы register allocator). Недостижимый блок — ПРЕДУПРЕЖДЕНИЕ (`is_error = false`), не отклоняет функцию (может быть легитимным). `instrRefs` (dst, операнды одной инструкции) — ИСЧЕРПЫВАЮЩИЙ switch по `mir.Instruction` (не `#partial`/`else`), тем же принципом, что `core/gc.odin`'s get_header/mark_value — новый вариант инструкции без кейса здесь не скомпилируется.

Одно отличие от Odin, задокументированное в самом файле: `validateFunction`/`validateModule` принимают `void_type: types.TypeId` явным параметром, а не сравнивают с зашитым индексом — `mir.Module`/`mir.Function` не хранят ссылку на живой `types.TypeStore`, из которого они построены (MIR хранит только уже разрешённые `TypeId`), а угадывать "какой TypeId означает Пусто" любым другим способом здесь означало бы молча полагаться на конкретный порядок аллокации в `TypeStore.init` — знание, которому место в `types.zig`, не тут.

### Реальный баг, найденный при подключении (не при чтении порта)

`mir_cfg.computeCfgInfo` индексирует массив predecessors НАПРЯМУЮ по сырому block id без проверки границ (осознанный компромисс производительности — эта функция гоняется на КАЖДОЙ лоуренной функции, ей не нужна оверхед хеш-мапы на доверенном входе). Из-за этого тест на "Jump на несуществующий блок 99" не просто репортил ошибку — он ронял процесс `index out of bounds` прямо внутри самой валидации, вызванной ИЗ-ЗА этого же самого сломанного terminator'а. Раньше это было невидимо, потому что ничто раньше не гоняло CFG-анализ на непроверенном/потенциально сломанном MIR — `wasm_emit.zig` всегда работал на уже успешно лоуренном (следовательно валидном по построению) MIR. Исправлено: `validateFunction` теперь трекает `has_bad_block_ref` и пропускает reachability-проход (`computeCfgInfo`), если хоть один terminator уже указывает на несуществующий блок — структурная ошибка уже отрепорчена, и «дальше нельзя доверять» применяется здесь так же, как и к остальным структурным ошибкам. `mir_cfg.zig` получил явный doc-comment с этим предусловием для будущих вызывающих.

### Подключение в wasm_emit.zig

`emitModule` теперь вызывает `validateOrFail` ПЕРЕД любой эмиссией — если найдена хоть одна структурная ошибка, печатает её и возвращает `error.InvalidMir` вместо попытки эмитировать (что раньше могло упасть с нерелевантным паникой глубоко внутри `processFrom`'а). Предупреждения (недостижимые блоки) логируются, но не блокируют — та же градация серьёзности, что в самом `mir_validate.zig`.

### Тесты

`mir_validate.zig`: 3 новых теста — Jump на несуществующий блок, нарушение single-use инварианта (значение как оба операнда `Binary`), недостижимый блок репортится именно как ПРЕДУПРЕЖДЕНИЕ, а не ошибка. `wasm_emit.zig`: новый тест — `emitModule` на заведомо сломанном MIR (Jump на блок 99) возвращает `error.InvalidMir` вместо падения. `zig build test`/`conformance`/`lsp`/`browser` — все зелёные, 3 повтора `test` без флейков (1102/1102 тестов).

### Итог по T043 — основная цель ЗАКРЫТА

"MIR, lowering, validation, stackification and binary emission" — все пять частей сделаны для Phase-1a подмножества: числа/булевы, локали (включая присваивание), арифметика/сравнения/унарные операторы, если/иначе, реальные итерирующие пока-циклы, прямые вызовы функций, возврат, плюс структурная валидация перед эмиссией. НЕ сделано (осознанно, Фаза 2+): присваивание в структуры/массивы, `zig/wasm_runtime/` object-table рантайм для агрегатов/массивов/строк/замыканий/интерфейсов, `panos build --target=wasm` CLI-обвязка (T048).

## T048 — panos build --target=wasm CLI-контракт

`zig/cli/main.zig`'s `build`-подкоманда — раньше просто печатала "Zig AOT-сборка ещё не поддержана" и выходила с кодом 1, теперь реальная реализация: `panos build --target=wasm <файл.ps> [-o выход.wasm]`. Пайплайн: `runner.analyzeSource` (уже существующий single-file анализ — лексер→парсер→резолвер→тайпчекер через `module_loader.Graph` с одним пользовательским модулем + подключённым embedded prelude) → `SourceAnalysis.tree()`/`.resolution()`/`.checkedResult()` → `mir_lowering.lowerModule` → `wasm_emit.emitModule` (включает валидацию через `mir_validate.zig`, см. T043) → запись байт в выходной файл.

Намеренно однофайловый — тем же ограничением, что и у `mir_lowering.zig`'s собственный скоуп (лоурит РОВНО один `ast.Ast`, без module-graph awareness), и `runner.analyzeSource`'s single-file entry point УЖЕ отклоняет реальный `импорт` заранее (`reportUnsupportedImports`) — эти два ограничения совпадают сами по себе, это не искусственное сужение специально под эту команду. В отличие от Odin's `run_build` (`main.odin`, полный multi-file module graph через `lower_program_graph`) — кросс-модульной wasm-сборки пока нет; это потребовало бы сначала научить `mir_lowering.zig` работать с graph'ом модулей, не с одним AST.

Диагностика ошибок на каждом шаге печатается с корректным path:line:col (переиспользован существующий `writeGraphDiagnostics`, с fallback на голое сообщение — новый `writeAnalysisDiagnostics` — для редкого случая, когда `analysis.graph` всё ещё `null`, т.е. отказ произошёл ДО построения графа, в `reportUnsupportedImports`). `wasm_emit.emitModule`'s `error.InvalidMir` (T043) и файловые ошибки чтения/записи тоже дают понятное сообщение + exit 1, а не необработанный crash.

Одна документированная граница: `mir_lowering.zig`'s `unsupported()` — это НЕПЕРЕХВАТЫВАЕМЫЙ `@panic`, не `error` — файл, использующий что-то за пределами Phase-1a (ADT/замыкания/интерфейсы/`для`/методы/...), уронит саму сборку с этим паническим сообщением, а не завершится чистым `exit(1)`. Текущее ограничение, не обходится этой командой — то же самое верно и для остального Phase-1a среза.

### Реальная проверка

Ручной smoke-test через собранный бинарник (не просто юнит-тест): `panos build --target=wasm loop_test.ps` на аккумулирующем `пока`-цикле (`сумма_до`, тот же пример, что в T043) → записанный `.wasm` реально исполнен через `wasmtime run --invoke сумма_до ... 10` → `45`. Также проверены: `-o custom.wasm` (кастомное имя выхода), `--target=native` (отклоняется с понятным сообщением, exit 1), синтаксически некорректный файл (`неизвестно` — неразрешённое имя, диагностика с точной `path:line:col`, exit 1).

Юнит-тестов на саму `main.zig`'s `runBuild` НЕТ — она использует `std.process.exit` на всех путях ошибок, что делает её недоступной обычному Zig-тесту (тем же прецедентом, что и остальной существующий `main()`: тесты в этом файле бьют по `runner.analyzeSource`/`formatDiagnostic` напрямую, никогда по `main()` целиком). Корректность пайплайна уже покрыта юнит-тестами в `wasm_emit.zig`/`mir_lowering.zig` (T043) — здесь добавлена только тонкая CLI-обвязка поверх уже проверенных функций, и подтверждена вручную реальным запуском.

`zig build test`/`conformance`/`lsp`/`browser` — все зелёные, 2 повтора `test` без флейков.

## T044 — WASI/JS AOT runtime модули: реальный порт + реальный найденный баг сборки

`zig/wasm_runtime/runtime_wasi.zig`/`runtime_js.zig` были голыми заглушками (только `panos_runtime_abi_version`). Порт из `wasm_runtime/runtime_wasi.odin`/`runtime_js.odin`, но сужен под то, что Phase-1a реально может позвать: ТОЛЬКО `pw_monotonic_ms`/`pw_now_ms` (время::монотонно_мс/сейчас_мс). `pw_print_string`/`pw_println_string` НЕ портированы — им нужен object-table рантайм (`arena`/`obj_offsets`/`obj_sizes`/`pw_string_ptr` в Odin-оригинале), а `wasm_emit.zig`'s Phase-1a вообще никогда не лоурит строковую константу (`unsupported()` на `const_value` со строкой) — эмулировать object-table-контракт заранее, без единого реального вызывающего до Фазы 2, означало бы гадать на пустом месте.

`runtime_wasi.zig` — `std.os.wasi.clock_time_get(.MONOTONIC/.REALTIME, ...)` напрямую (тот же `core:sys/wasm/wasi` эквивалент, что Odin использует, только через `std.os.wasi` вместо отдельного Odin-пакета). `runtime_js.zig` — `extern "js_runtime" fn now_ms/monotonic_ms`, тот же контракт (модуль импорта `"js_runtime"`, те же имена функций), что Odin's `foreign import js_rt "js_runtime"` — один и тот же `docs/src/assets/aot-dom-loader.js` подходит для рантайма, собранного ЛИБО тулчейном.

### Реальный баг, найденный тестами (не чтением порта)

Собранный `panos-aot-runtime-wasi.wasm` оказался ВСЕГО 44 байта — байткод-дамп показал: экспортирована ТОЛЬКО `memory`, ни одной функции. `wasm-ld` вычищал КАЖДУЮ `pub export fn`, потому что ничто в этой же единице компиляции их не звало (весь смысл этого модуля — быть вызванным ИЗВНЕ, отдельно эмитированным `panos build --target=wasm` модулем или JS-загрузчиком), а `addWasmRuntime` (`build.zig`) не выставлял `rdynamic`, в отличие от `browser`-исполняемого файла чуть выше в том же `build.zig` (`browser.rdynamic = true`), который эту проблему уже решил для другого случая. Это была бы 100%-скрытая проблема без реального `wasmtime`-запуска — "собралось" и "структурно валидно" здесь ничего не говорили о наличии экспортов. Исправлено: `runtime.rdynamic = true;` в `addWasmRuntime`. После фикса — `pw_now_ms`/`pw_monotonic_ms`/`panos_runtime_abi_version` все на месте, подтверждено побайтовым дампом секции экспортов И реальным `wasmtime run --invoke`.

### Тесты

Новый `tests/wasm/aot_runtime_test.zig`, подключён в `build.zig`'s `test_step` с явной зависимостью от `install_runtime_wasi`/`install_runtime_js` (тест не собирает рантаймы сам, только читает уже установленные `.wasm` из `zig-out/bin/`). 5 тестов: реальный `wasmtime run --invoke pw_now_ms` → правдоподобный epoch-ms диапазон (2020–2100 гг.), `pw_monotonic_ms` → неотрицательное число (СРАВНИВАТЬ с байткод-VM's `время.монотонно_мс` численно НЕЛЬЗЯ — разные эпохи отсчёта, разные процессы, тот же нюанс, что в Odin-оригинале задокументирован), `panos_runtime_abi_version` → `0`; плюс два структурных теста контракта (байтовый substring-поиск по экспортам/импортам в самом `.wasm`, не полноценный WASM-парсер декодирования — `wasm_module.zig` кодирует, не декодирует) — `panos-aot-runtime-wasi.wasm` экспортирует ровно три задокументированные функции, `panos-aot-runtime-js.wasm` экспортирует их же И импортирует ровно `js_runtime.now_ms`/`js_runtime.monotonic_ms` (JS-раннер напрямую через wasmtime не проверить — нет `js_runtime` host-контракта в самом wasmtime — поэтому только контрактная, не исполняющая проверка). `zig build test`/`conformance`/`lsp`/`browser` — все зелёные, 4 повтора `test` без флейков (1107/1107 тестов).

### Итог по T044

`pw_monotonic_ms`/`pw_now_ms` реально портированы и работают на обеих платформах (WASI подтверждено выполнением, JS — контрактом). НЕ сделано (осознанно, ждёт Phase 2 object-table рантайма): `pw_print_string`/`pw_println_string` на обеих платформах — единственные функции ABI, которым реально нужен object-table, а он не существует ни на одной стороне до тех пор, пока `mir_lowering.zig`/`wasm_emit.zig` не научатся лоурить строки/агрегаты.

## T036 — module/prelude/generic/ADT conformance-фикстуры: реальный, не только организационный пробел

Формулировка задачи в `tasks.md` изначально считала это чисто организационным долгом ("всё уже покрыто 24 инлайн-тестами `module_compiler.zig`, просто не в виде отдельных `.ps`-файлов"). Проверка боем показала обратное: ВСЕ существующие multi-module тесты (`module_compiler.zig`'s 24 теста, `module_loader.zig`'s cycle/missing-module тесты) используют `MemoryReader` — фейковый in-memory ридер, никогда не настоящий, дисковый `Io`/`std.Io.Dir.cwd().readFileAlloc`, которым РЕАЛЬНО пользуются `panos run`/`panos build` (`zig/cli/main.zig`'s собственный `FileReader`). Грепом по всему `zig/`-дереву подтверждено: до этой задачи НИЧТО не гоняло `module_loader.Graph.load` по настоящим файлам на диске, кроме самого `main.zig`.

Новое: `tests/conformance/modules/` — 9 настоящих multi-file `.ps` фикстур-проектов (`basic_import` — cross-file вызов+константа; `three_file_chain` — 3-файловая транзитивная цепочка main→mid→leaf; `generic_struct` — импортированная generic-структура + метод; `adt_match` — импортированный generic-перечисление, конструирование+исчерпывающий match; `adt_non_exhaustive` — тот же тип, но НЕисчерпывающий match, негативный кейс; `interface_dispatch` — cross-module интерфейс `Сравниваемое`; `prelude_merge` — `Опция` без единого `импорт`; `missing_export`/`cycle` — два негативных диагностических кейса) + `tests/conformance/modules_test.zig` (собственный `FileReader`, дословно зеркалящий `main.zig`'s, `Graph.load` + `compileGraph` + реальный запуск VM либо проверка диагностики — 9 тестов, по одному на фикстуру).

### Реальная находка, обнаруженная попутно

`zig/cli/main.zig`'s настоящий путь `panos run`/`panos build` НИКОГДА не вызывает `appendPreludeModule` — но `Опция`/`Результат`/`Сравниваемое` при этом РАБОТАЮТ (подтверждено вручную реальным собранным бинарником ДО написания теста). Причина — СОВЕРШЕННО ОТДЕЛЬНЫЙ, хардкоженный fallback-механизм в `resolver.zig` (`installPreludeEnum`/`installPreludeInterface`, включается флагом `skip_prelude_hardcode`), никак не связанный с module-graph-based слиянием, которым пользуется `runner.zig`'s single-file `analyzeSourceForTarget` (та ДЕЙСТВИТЕЛЬНО зовёт `appendPreludeModule` с настоящим `prelude.SOURCE`). Два независимых, параллельных механизма решают одну и ту же задачу для двух разных входных путей — раньше это нигде не было явно задокументировано и не проверялось тестом. `prelude_merge`-фикстура теста НАРОЧНО повторяет поведение именно CLI (без `appendPreludeModule`), не `runner.zig` — и является единственным тестом, который поймал бы регресс, если бы хардкоженный резолверный fallback когда-нибудь убрали, предположив, что module-graph prelude — единственный механизм.

### Тесты и подключение

`modules_test.zig` подключён и в `test_step`, и в `conformance_step` (`build.zig`) — потребовал того же `.link_libc = true` + `sqlite_lib`/`libffi_archive` линковки, что `native_integration_tests` (прямой вызов `vm.Vm.run` тянет эти символы, в отличие от существующих lexer/parser-conformance тестов, которые их не трогают — без этой линковки — 22 undefined symbol ошибки на этапе сборки теста, тем же паттерном, что раньше уже решался для `native_integration_tests`). `zig build test`/`conformance`/`lsp`/`browser` — все зелёные, 3 повтора `test` без флейков (1116/1116 тестов).

## T047 (частично) — textDocument/semanticTokens/full

Перед стартом спросил пользователя, с чего продолжать T047 (`semanticTokens/full` — самостоятельная фича, без новой архитектуры, vs cross-document definition/references — реально требует новый workspace-wide symbol-индекс, настоящая архитектурная развилка, vs переключиться на US4). Выбрано: `semanticTokens/full` сначала.

Новый `zig/core/semantic_tokens.zig`, дословный порт `core/semantic_tokens.odin`: классифицирует КАЖДОЕ `.ident`-выражение из `resolution.expr_symbols` по УЖЕ посчитанному резолвером `Symbol.kind` (не по regex/конвенции имени — с кириллицей нет единой конвенции вроде "тип с большой буквы"). `namespace`/`type`/`enumMember`/`function`/`variable`/`parameter` — порядок в `token_type_names` ДОЛЖЕН совпадать с LSP-протокольным legend (индекс массива — это и есть token type). Параметр отличается от обычной `пер`-локали ТОЛЬКО членством символа в чьём-то `resolution.function_parameters` — оба имеют `SymbolKind.variable`, разница исключительно в происхождении. Намеренно НЕ классифицирует `.property`-доступ (`x.поле`/`x.метод()`) — резолвер также пишет резолвленный символ под ID ЦЕЛОГО `Property`-выражения (для go-to-definition на `математика.пи()`), и без фильтра "только `.ident`" получился бы дублирующийся, перекрывающий токен на весь `математика.пи`, а не только на имя модуля — поймано отдельным тестом-регрессией (та же ситуация, что различительное тестирование нашло в Odin-оригинале).

`zig/lsp/main.zig`'s новый `semanticTokensFull` — дословный порт `lsp_server.odin`'s `handle_semantic_tokens`: позиция каждого токена через `SourceFile.byteOffsetToUtf16Position`, guard на однострочность (идентификаторы в panos всегда однострочные, но лучше молча пропустить нарушающий спеку токен, чем прислать его клиенту), сортировка по (line, character), затем стандартное относительное дельта-кодирование LSP (`deltaLine, deltaChar, length, tokenType, tokenModifiers` — `deltaChar` отсчитывается от предыдущего токена ТОЛЬКО если та же строка, иначе от начала строки). Capabilities JSON — новый `semanticTokensProvider` с 6-элементным legend, порядок в точности как в `SEMANTIC_TOKEN_TYPE_NAMES`.

### Реальная проверка

Не только юнит-тесты — реальный запущенный процесс `panos-lsp` (Python-скрипт, LSP-фрейминг вручную): документ `сложить(a: Число, b: Число) -> Число \n a + b \n конец \n старт() -> Число \n сложить(20, 22) \n конец` → `textDocument/semanticTokens/full` вернул РОВНО 3 токена — `a`/`b` как parameter (внутри `a + b`), вызов `сложить` как function (внутри `старт`) — раскодировано вручную из дельта-кодирования и подтверждено побайтово корректным (позиции, длины в рунах, включая корректную длину "сложить" = 7 кириллических символов).

### Тесты

`semantic_tokens.zig`: 2 теста (классификация по видам символов на разнообразной программе; отсутствие дублирующегося токена на module-qualified вызове — используется РЕАЛЬНЫЙ native builtin-модуль `фс` вместо Odin-оригинала `строки`, т.к. в Zig-порте `строки` — не встроенный модуль, а файл `std/строки.ps`, недоступный однофайловому резолверному тесту). `zig/lsp/main.zig`: обновлён capabilities-тест + новый transcript-тест (проверяет наличие токенов parameter/function в ответе на реальном многошаговом транскрипте). `zig build test`/`conformance`/`lsp`/`browser` — все зелёные, 3 повтора `test` без флейков (1151/1151 тестов).

### Что всё ещё не сделано в T047

Cross-document `definition`/`references` — нужен настоящий workspace-wide symbol-индекс по рёбрам `модуль`/`импорт`, которого у этого LSP пока нет вообще; осознанно отложено (подтверждено пользователем) как отдельная архитектурная развилка, не сделанная в рамках этого среза.

## T050 — документация нового пайплайна и границ рантайма

Первая задача US4 (административный хвост миграции). `docs/src/architecture/toolchain-and-testing.md`'s раздел "Zig-тулчейн" был написан рано в миграции и успел устареть по нескольким пунктам: называл `zig build aot-runtime-js`/`-wasi` заглушками (после T044 — реальные, с проверенным `wasmtime`-запуском), не упоминал `panos build --target=wasm` вообще (T048 тогда ещё не существовал), занижал число тестовых целей (~15 вместо реальных ~35) и всё ещё ссылался на T044/T056 как на "нет smoke-теста" (оба уже закрыты). Приведено в соответствие.

Добавлен новый раздел "MIR→WASM AOT-пайплайн (Zig, T043/T048)" — то, что у Odin-реализации попросту не существует как отдельного концепта (Odin никогда не строил MIR — там `wasm/main.odin`, отдельная browser-интерпретаторная сборка, а не AOT-компиляция пользовательской программы в самостоятельный `.wasm`). Раздел покрывает: роль каждого из 8 новых файлов (`mir.zig` → `wasm_emit.zig`), точную границу Phase-1a лоуринга, single-use-ValueId инвариант (почему `wasm_emit.zig` вообще может быть чисто стековым, без register allocator'а), `mir_cfg.zig`'s предусловие насчёт непроверенных block-id (реальный баг, найденный при подключении `mir_validate.zig` — задокументирован здесь как предостережение будущим читателям кода, не только в progress-report.md), и границу AOT-рантайма (что реально портировано — `pw_monotonic_ms`/`pw_now_ms` — против того, что ждёт Phase 2 object-table рантайма — `pw_print_string`/`pw_println_string`). Новая таблица "точки входа для типичной правки MIR/WASM-пайплайна", тем же форматом, что уже существующие таблицы точек входа для Odin- и обычного Zig-тулчейна.

`mdbook build` — чисто, без ошибок/warnings.

## T051 — CI Zig build matrix + реальный найденный баг с PATH/environ

Новый `.github/workflows/zig-ci.yml` — push на main/pull_request/workflow_dispatch, та же 3-платформенная матрица, что `release-binaries.yml` (ubuntu-24.04/macos-14/windows-2022 — совпадает с платформами, для которых уже есть прекомпилированные `external/sqlite3`/`external/libffi` архивы, пересборка не нужна). Гоняет `zig build test`/`conformance`/`lsp`/`browser`/`aot-runtime-wasi`/`aot-runtime-js` на каждой платформе. `wasmtime` ставится явно через официальные install-скрипты (не сторонний Action), чтобы T043/T044's реальные `wasmtime run --invoke`-тесты действительно выполнялись в CI, а не тихо скипались.

ВАЖНО: сам workflow не удалось прогнать сквозно в этой среде (нет доступа к настоящему GitHub Actions раннеру) — YAML проверен на синтаксическую валидность (`python3`+`pyyaml`), и каждая отдельная команда внутри (`zig build test`/`conformance`/`lsp`/`browser`/`aot-runtime-*`) проверена локально — но сам workflow нужно понаблюдать на первом реальном запуске в CI.

### Реальный баг, найденный при написании workflow (не сам CI-конфиг)

Три wasmtime-вызывающих теста (`wasm_emit.zig`×2, `tests/wasm/aot_runtime_test.zig`×3) в предыдущих сессиях этой же миграции были "исправлены" на `.expand_arg0 = .expand` с голым `"wasmtime"` вместо захардкоженного `/opt/homebrew/bin/wasmtime` — но `Io.Threaded.Options.environ` по умолчанию ПУСТОЙ (осознанный дизайн — наследование реального окружения дочернего процесса должно быть explicit opt-in), а `expand_arg0`'s поиск по `$PATH` читает ИМЕННО это (всегда-пустое-если-не-задано) поле, не реальное окружение ОС — тихо откатывается на захардкоженный `/usr/local/bin:/bin:/usr/bin` и возвращает `FileNotFound`, даже когда wasmtime реально есть в `$PATH`. Подтверждено минимальной репродукцией (`zig test` на изолированном файле) ДО правки настоящего кода, не гипотезой. Реальный фикс — передать `.environ = std.testing.environ` (реальное окружение процесса, которое уже перехватывает и раздаёт стандартный test runner Zig) в каждый `Io.Threaded.init`, спавнящий wasmtime.

До фикса `zig build test` тихо репортил "1146/1151 passed (5 skipped)" вместо "1151/1151" — wasmtime-тесты проходили ЛОЖНО (через `SkipZigTest`, не реальное исполнение) на любой машине, где wasmtime не установлен ровно по тому захардкоженному абсолютному пути, что зашила предыдущая сессия — это осталось бы незамеченным в добавляемой прямо сейчас CI-матрице, если бы не поймалось при написании самого workflow. После фикса — 1151/1151, ноль скипов, подтверждено. `zig build test`/`conformance`/`lsp`/`browser` — все зелёные, 3 повтора `test` без флейков.

## T052 — базовые показатели производительности и пороги регрессии

Инфраструктуры бенчмарков не было НИ У ОДНОГО тулчейна до этой задачи (проверено грепом по всему репозиторию). Построено с нуля: три однофакторные `.ps`-фикстуры в `tests/conformance/benchmarks/` — `fib_recursive.ps` (только call-путь: рекурсия, без циклов/аллокаций), `loop_sum.ps` (только цикл/сравнение/арифметика: `пока` на 5 000 000 итераций, без вызовов/аллокаций), `string_concat.ps` (только аллокатор/GC: 20 000 конкатенаций `+`, panos-строки не интернированы и неизменяемы — каждая конкатенация аллоцирует новую строку). Замерено 5 прогонов на бинарник на фикстуру, релизные сборки с обеих сторон (`odin build . -o:speed`, `zig build -Doptimize=ReleaseFast`), на реальной машине этой сессии (Apple M4/macOS, Odin `dev-2026-06:285f6d87b`, Zig `0.16.0`) — зафиксировано в документе для воспроизводимости, раз абсолютные числа имеют смысл только на одной и той же машине.

### Реальная находка

Zig-байткод-VM заметно медленнее Odin-эталона на call-пути (~1.26×) и особенно на цикл-пути (~1.56×), но БЫСТРЕЕ на аллокатор/GC-пути (~0.79×) — устойчивый, малошумный, воспроизводимый разрыв (не погрешность замера — низкий разброс между прогонами). Задокументировано как наблюдение для будущего расследования, ЯВНО не задача на исправление в рамках T052 (это задача "зафиксировать baseline", не "оптимизировать") и явно не блокер cutover'а на этой стадии (корректность важнее сырой скорости сейчас).

### Пороги регрессии

Определены относительно СОБСТВЕННОГО Zig-baseline этой сессии (не относительно Odin — тот референсная точка, не жёсткое требование, раз Zig уже обгоняет его по одной оси и отстаёт по двум): рост Zig-времени фикстуры больше 15% от записанного baseline — предупреждение; больше 30% — блокер релиза, требующий либо исправления, либо явного задокументированного компромисса ПЕРЕД поднятием нового baseline. Новый baseline — новая строка в таблице `benchmarks.md`, не правка старой цифры на месте (git-история — источник истины "как менялась производительность со временем").

`zig build test`/`conformance`/`lsp`/`browser` — все зелёные и после добавления фикстур (они не подключены ни к одному Zig-тесту — чисто ручной бенчмарк-артефакт, соответствует собственному скоупу задачи).

## T053 (частично) — реальный прогон conformance-матрицы, три реальные находки

Схема `zig/conformance/manifest.zig`'s `Case` содержала только `id`/`tier`/`profile` — ни один case никогда не был заполнен (`manifest.json` был буквально `{"cases":[]}`). Дополнено до полной формы контракта (`specs/010-zig-migration/contracts/conformance.md`): `input` (реальный путь `.ps`-файла от корня репо) + `expected: outcome.Outcome`. Заполнено 5 реальных cases (2 `semantic`, 3 `runtime`) — КАЖДЫЙ проверен РЕАЛЬНЫМ прогоном свежесобранного Odin-эталона (`odin build . -o:speed`) БОК О БОК с Zig-CLI на одном и том же `.ps`-файле, не предположением. Новый `zig/conformance/matrix_test.zig` (подключён в `test_step`+`conformance_step`) прогоняет каждый case через Zig и проверяет, что записанный `expected`-outcome всё ещё держится — это АВТОМАТИЧЕСКАЯ половина гейта; роль Odin была одноразовым ручным сравнением для заполнения манифеста, не проверкой на каждый прогон (для этого `reference.zig`'s `runFile` потребовал бы того же `Io.Threaded`-environ фикса, что T051 — вне скоупа здесь).

### Две реальные находки, записанные как деклассифицированные девиации (DEV-001/DEV-002)

1. Odin's форматирование чисел (`fmt.tprintf("%v", f64)`) переключается на научную нотацию выше ~15 значащих цифр (`12499997500000` → `1.24999975e+13`), Zig's `renderValue` — нет. Тот же самый эффект, что уже задокументирован в памяти проекта для `строки.из_числа` — одобрено как есть, Odin уходит на пенсию, незачем повторять его квирк в Zig.
2. Zig's `Type Error: функция должна возвращать объявленный тип` (обобщённое) реально МЕНЕЕ информативно, чем Odin's `Type Error: функция должна возвращать 'X', но последнее выражение имеет тип 'Y'` (называет оба типа) — настоящий, отслеживаемый пробел в качестве сообщения (`type_checker.zig`'s `checkFunction` не имеет доступа к форматтеру имени типа в месте вызова; `runner.zig`'s `formatTypeName` существует, но не подключён туда) — НЕ исправлено здесь (вне скоупа T053 "зафиксировать и классифицировать"), оставлено помеченным follow-up'ом.

### Третья, более крупная находка — НЕ втиснута в манифест силой

`resolver.zig`'s `installBuiltins` делает нативные builtin-модули (`фс`/`ос`/`сеть`/`бд`/`сжатие`/`синтаксис`) ambient/всегда-в-scope БЕЗ `импорт` — и через реальный многофайловый `module_loader.Graph`-путь `импорт фс` даже НЕ РАБОТАЕТ (пытается загрузить несуществующий файл `фс.ps` и падает). Odin требует явный `импорт <модуль>` для тех же builtin-модулей (подтверждено: в `core/resolver.odin` нет безусловного `install_builtin_module`-эквивалента; каждый native-builtin e2e-тест в `core/e2e_*.odin` явно импортирует). Это настоящее, фундаментальное, ПРЕДНАМЕРЕННОЕ упрощение из более ранней части этой миграции (не внесено в этой сессии), не случайный баг — но означает, что native-tier фикстуры физически нельзя написать В ОДНОЙ форме, работающей на обоих реальных CLI одновременно. Задокументировано как известная архитектурная девиация, НЕ закодировано как case манифеста (потребовало бы либо двух вариантов фикстуры, либо profile-уровневого исключения, которого текущая схема не моделирует).

### Почему "частично"

Заполнены только `semantic`/`runtime` tiers. `lexer`/`parser` уже имеют равноценное покрытие через собственные харнессы (`lexer_test.zig`/`parser_test.zig`) — не дублировалось. `native`/`browser`/`aot`/`lsp` tiers остались БЕЗ cases в манифесте (native заблокирован находкой выше про `импорт`; browser/aot/lsp нуждаются в харнессах, которых ещё нет).

`zig build test`/`conformance`/`lsp`/`browser` — все зелёные (1155/1155 тестов). Замечено: `native_integration_tests`/`conformance` иногда занимали ~5 минут в этой песочнице (похоже на медленный тайм-аут `http_client_error.ps`'s connection-refused проверки) — не связано с изменениями этой задачи, не регресс от неё.

## T054/T055/T056 — валидация контрактов CLI/LSP/WASM, реальный найденный краш LSP-сервера

Только macOS/arm64 (единственная машина этой сессии) — "все релизные платформы" (linux-amd64/windows-amd64 из `release-binaries.yml`'s матрицы) НЕ покрыты здесь, оставлено на реальный прогон нового `zig-ci.yml` (T051).

### T054 — CLI-контракт: два реальных нарушения

Каждый пункт `contracts/cli.md` проверен на РЕАЛЬНОМ `zig-out/bin/panos` (не чтением исходников): имя исполняемого файла, позиция `-v`/`--verbose` + проброс аргументов программы через `ос.аргументы()`, ограничение `build` только `--target=wasm`, дефолтное имя `-o`, сообщение `panos build: записан <path>`, реальный проброс exit-кода (`ос.завершить(7)` → код возврата 7), формат диагностик `path:line:column: message`.

Найдено два реальных нарушения контракта:
1. "Без file.ps panos запускает существующий REPL" — Zig печатает "Panos REPL ещё не поддержан Zig-версией" и выходит с кодом 0 вместо запуска REPL. Известный, уже закомментированный в коде пробел — но ранее никогда не сверялся именно с текстом контракта.
2. "warnings печатаются, но сами по себе не блокируют выполнение" — на Zig-стороне это условие ВЫПОЛНЯЕТСЯ ЛОЖНО-ТРИВИАЛЬНО: ни один реальный диагностик нигде в `zig/core/*.zig` не использует `.severity = .warning` (проверено грепом) — то есть предупреждений просто НЕТ вообще. У Odin есть ДВЕ реальные warning-проверки (неиспользуемая переменная — `resolver.odin`; недостижимый код — `type_cheker.odin`), ни одна не портирована на Zig. Подтверждено: свежесобранный Odin-эталон реально печатает `warning: неиспользованная переменная 'x'` и всё равно выполняет программу. Оба пункта — реальные, отслеженные пробелы, НЕ исправлены здесь (REPL и два новых warning-чекера — существенные фичи, далеко за пределами "проверить контракт").

### T055 — LSP-контракт: найден и исправлен реальный краш-баг

Все 18 обязательных методов из всех 3 групп контракта подтверждены подключёнными в `zig/lsp/main.zig` (грепом, сверено построчно с таблицей контракта). Проверено на РЕАЛЬНО запущенном `panos-lsp` (Python + ручной LSP-фрейминг): `definition`/`hover` на несуществующий документ или дикую вне-диапазона позицию — оба возвращают `{"result":null}`, никогда исключение, сервер остаётся живым и отвечает на следующий, не связанный запрос.

НАЙДЕН И ИСПРАВЛЕН реальный краш: искажённый транспортный фрейм (мусорные байты без заголовка `Content-Length:`) заставлял ошибку `readMessage` пройти напрямую через `main`'s `while (try readMessage(...))`'s `try`, роняя ВЕСЬ процесс сервера (необработанный `error.MissingContentLength`, код выхода 1) вместо продолжения или чистого завершения — подтверждено реальной репродукцией через subprocess ДО и ПОСЛЕ фикса. Исправлено в `zig/lsp/main.zig`'s `main`: транспортная ошибка framing теперь логируется в stderr (`панос-lsp: транспортная ошибка, останавливаюсь: ...`) и завершает цикл чтения обычным `exit(0)`, а не необработанной паникой — реальные LSP-клиенты всегда шлют корректные фреймы, так что это маловероятно на практике, но "весь языковой сервер редактора падает" — строго худший отказ, чем чистое завершение, вне зависимости от вероятности. `zig build lsp`/`test` перепроверены зелёными после фикса.

### T056 — Browser/AOT WASM: реальное сквозное исполнение браузерного интерпретатора

AOT-сторона уже покрыта T044's `tests/wasm/aot_runtime_test.zig` (реальный `wasmtime`-запуск). Браузерная сторона не имела НИКАКОЙ реальной проверки исполнения раньше — `panos-browser.wasm` не имеет НИ ОДНОГО WASM-импорта (подтверждено `wasm-objdump -h`: секции Import вообще нет) и общается исключительно через собственную экспортированную линейную память (`panos_source_ptr`/`panos_source_capacity`/`panos_run`/`panos_result_ptr`/`panos_result_len`) — значит вызываем из ЛЮБОГО WASM-хоста, не только браузера. Проверено вручную через Python-биндинги `wasmtime` (установлены для этой ОДНОЙ проверки, НЕ подключены к `zig build test` — добавили бы новую внешнюю Python-зависимость без прецедента в проекте, в отличие от CLI-бинарника `wasmtime`, уже обязательного для T044/T051): записана UTF-8-строка в память по `panos_source_ptr()`, вызван `panos_run(len)`, прочитан результат из `panos_result_ptr()`/`panos_result_len()` — `2 + 3` → `"5"`, сломанная программа → реальный текст `Resolve Error: неопределённое имя 'неизвестно'`, строковый литерал → `"панос"`. Реально доказывает, что браузерный интерпретатор исполняет настоящие panos-программы ВНЕ браузера, а не просто "файл структурно валиден". Оставлено ручной проверкой (задокументировано здесь), не автоматическим Zig-тестом — из-за лишней Python-зависимости, которую это потребовало бы.

## T057/T058/T059 — cutover: Zig становится релизным тулчейном

`Justfile`'s `build`/`build-lsp`/`build-wasm`/`build-all` теперь собирают через `zig build`/`zig build lsp`/`zig build browser`, копируя артефакт на ТОТ ЖЕ путь, что раньше давала Odin-версия (`./panos`, `./panos-lsp`, `demo/panos.wasm`) — ни один существующий потребитель (редакторские LSP-конфиги, `deploy-pages.yml`'s `cp -r demo/.`) не сломан. Заодно снята старая оговорка "Ритуал редеплоя" про разный путь установки — теперь `just build-lsp` всегда кладёт бинарник в корень репо независимо от тулчейна под капотом. Odin-рецепты СОХРАНЕНЫ, переименованы `*-odin` — Odin остаётся собираемым по требованию (нужен для T053-стиля сравнения). `bump-and-push` теперь гоняет `zig build`/`zig build test` как гейт и обновляет версию в ОБОИХ местах (`core/vm.odin` И `zig/core/vm.zig`'s `osVersion` — раньше рецепт обновлял только Odin-сторону, реальный риск рассинхронизации, пойманный только при внимательном разборе для этой задачи).

`.github/workflows/release-binaries.yml`/`deploy-pages.yml` — `laytan/setup-odin@v2` + `odin build` заменены на `mlugg/setup-zig@v1` + `zig build`, та же 3-платформенная матрица (уже непрерывно проверяется `zig-ci.yml`, T051 — релизная сборка никогда не будет ПЕРВЫМ разом, когда именно эта платформа+optimize компилируется). `deploy-pages.yml` заодно потерял шаг установки system `lld`/`wasm-ld` — Zig таскает свой линкер сам. Подтверждено: `docs/src/assets/interactive.js` не потребовал НИ ОДНОЙ правки для этого свапа — уже feature-detect'ит `odin_env`-импорты против чистого memory-based контракта, которым пользуется Zig's `panos-browser.wasm` (двойная поддержка тулчейнов явно заложена раньше в этой же миграции, заранее под этот самый cutover). Каждая новая команда реально проверена локально: `just build`/`build-lsp`/`build-wasm` дают рабочие артефакты; новый `demo/panos.wasm` (уже Zig) реисполнён end-to-end тем же методом через Python `wasmtime`, что в T056 (`2+3` → `"5"`); `mdbook build` собирается с Zig-собранным `panos.wasm`.

`zig/conformance/reference.zig` (helper, шеллившийся в живой `odin run ...`) УДАЛЁН вместе с его тремя точками подключения в `build.zig` — единственный код, реально зависевший от установленного Odin в мандаторном пути, и не нужный больше теперь, когда T053 запёк статичные, уже проверенные `expected`-исходы прямо в `manifest.json`. Подтверждено грепом по `.github/workflows/*.yml`: ни `release-binaries.yml`, ни `deploy-pages.yml`, ни `zig-ci.yml` больше не трогают Odin вообще (только `vendor-libffi.yml`/`vendor-sqlite.yml` всё ещё его используют — но это `workflow_dispatch`-only обслуживание, не мандаторный гейт, осознанно не тронуто). `tests/conformance/README.md` переписан (был безнадёжно устаревшим — описывал состояние ДО того, как manifest.json вообще заполнили).

### T059 — решение: Odin-исходники ОСТАЮТСЯ

Новый раздел "Судьба Odin-исходников (T059)" в `docs/src/architecture/toolchain-and-testing.md`. Решение: ~47.6К строк Odin-кода (`core/*.odin`, `main.odin`, `lsp/`, `wasm/`, `wasm_runtime/*.odin`) НЕ удаляются сейчас — статус понижен до "reference-only", но физически остаются. Три причины: (1) Odin всё ещё реально полезен — T053 заполнил только 2 из 8 tier'ов манифеста, остальным нужно то же самое сравнение бок о бок с реальным Odin-бинарником; (2) удаление ~47.6К строк ощущается необратимым, даже с учётом git-истории — разница трения между "физически присутствует, статус понижен" и "полностью удалено" реальна для будущей диагностики; (3) естественный триггер ещё не наступил — сами находки T053-T056 этой сессии (нет REPL, непортированные warning-диагностики, cross-document LSP пробел, незаполненные tier'ы манифеста) всё ещё открыты, и удаление reference-реализации ДО их разбора убрало бы самый быстрый способ понять "а как это было у Odin" при их закрытии. Задокументировано конкретное, состояние-based (не дата-based) условие для будущего реального удаления: манифест заполнен по ВСЕМ 8 tier'ам + каждое найденное расхождение либо исправлено, либо формально принято как `ApprovedDeviation` + один полный релизный цикл Zig-бинарника в продакшене без найденной сравнением регрессии — тогда архивировать (тег+ветка, не голое `rm -rf`), отдельным, явно запрошенным действием, не бандлом с другой работой.

Заодно поправлены несколько других устаревших утверждений в том же документе, найденных при написании этого раздела: верхний "## Что" всё ещё описывал `just build`/`build-lsp`/`build-wasm` как Odin-команды (уже неверно после T057), таблица "Точки входа" смешивала Odin-специфичные строки с уже Zig-фасадными Justfile-рецептами (переименована в "для типичной Odin-правки", строки указывают на переименованные `-odin`-рецепты), вводный абзац "Zig-тулчейн" всё ещё утверждал "just-обёртки для него пока не заведены" (неверно — T057 их только что добавил). `mdbook build` чист после каждой правки. `zig build test`/`conformance`/`lsp`/`browser` — все зелёные после всех изменений T057-T059.

## T047 (продолжение) — cross-document definition/references

После REPL-фикса и порта warning-диагностик — закрытие последнего пробела T047: cross-document `definition`/`references`.

Новый `zig/core/lsp_graph.zig` — реальный `module_loader.Graph`-based анализ (не `runner.analyzeSource`, который однофайловый и явно ОТКЛОНЯЕТ любой `импорт`), с document-store-aware `Reader` (сперва проверяет открытые, возможно несохранённые буферы через `file://`-URI↔абсолютный-путь мост, иначе — реальный диск). Находка попутно: это закрывает пробел БОЛЬШЕ, чем "нет cross-document навигации" — ЛЮБОЙ документ с реальным `импорт` раньше не получал ВООБЩЕ НИКАКОЙ LSP-поддержки (каждый обработчик шёл через однофайловый, отклоняющий импорт путь) — cross-document был лишь ПОДМНОЖЕСТВОМ этой более крупной, ранее неизвестной проблемы.

`definition`/`references` (сознательно только эти два — остальные 12 обработчиков оставлены на однофайловом пути, отдельная, отдельно проверяемая задача на будущее) теперь резолвят происхождение символа через `resolver.Resolution.imported_symbols`, прыгают/ищут через файл ДЕКЛАРИРУЮЩЕГО модуля, когда он отличается от текущего документа, и — для `references` — дополнительно сканируют КАЖДЫЙ другой открытый документ, строя ЕГО СОБСТВЕННЫЙ независимый граф, ищя использования, резолвящиеся (по идентичности "путь декларирующего файла + span декларации", раз сырые `SymbolId`/`DeclId` имеют смысл только ВНУТРИ одной постройки графа) к той же цели.

### Реальная находка при отладке — пробел в самой сборочной системе

Новый файл `zig/core/*.zig` НЕ получает своих тестов в `zig build test` просто потому, что `root.zig` его `pub const`-экспортирует — Zig обнаруживает `test`-блоки ТОЛЬКО достижимые из СОБСТВЕННОГО корневого файла компиляции, а корень `core_tests` — сам `root.zig`, у которого ровно один свой инлайн-тест. Каждому остальному core-файлу (и теперь `lsp_graph.zig`) нужна СОБСТВЕННАЯ выделенная `b.addTest`-запись в `build.zig`. Поймано намеренно подложенным падающим assert'ом, который `zig build test` тихо НЕ ловил даже после полной очистки кеша (`.zig-cache` И `~/.cache/zig`) — подтверждено прямым `zig test <файл>` ДО правки `build.zig`.

Тесты: `lsp_graph.zig` (3, включая реальную многофайловую загрузку графа) + новый LSP-транскрипт-тест, открывающий два реальных документа (`main.ps` импортирует `математика.ps`), проверяющий, что `definition` прыгает между файлами, а `references` находит использования в обоих. Подтверждено на РЕАЛЬНО запущенном `panos-lsp`-процессе (не только юнит-тестами) — `definition` на вызове `сложить` в `main.ps` корректно указывает на `математика.ps:1:13-20`, `references` возвращает ОБА местоположения (декларация + использование) из РАЗНЫХ открытых документов.

`zig build test`/`conformance`/`lsp`/`browser` — все зелёные (1464/1464 тестов).
