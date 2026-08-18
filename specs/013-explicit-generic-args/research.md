# Research: Явный generic-argument синтаксис

## Decision: `ф[Тип](...)` разрешается семантически, не грамматически

**Rationale**: см. spec.md's "Контекст" — `[` после выражения уже
безусловно парсится как `Index_Expr` (`parser.zig:1696`, `parseIndex`),
и это не гипотетический, а рабочий кейс (`массив_функций[0](args)`).
Парсер однопроходный, без бэктрекинга. По образцу Go (`go/parser`+
`go/types`) — не менять грамматику, а переинтерпретировать уже
построенный `Index_Expr` в резолвере/тайпчекере, когда известно, что
объект индексации — generic-функция.

**Alternatives considered**: новый токен/сигил (`::[]`/`::<>`) —
отклонено пользователем как избыточное усложнение при наличии более
простого пути; полноценный бэктрекинг в парсере — отклонено, чужеродно
для архитектуры (см. `specs/005-language-fixes`, та же причина не
позволила решить похожую неоднозначность бэктрекингом там).

## Decision: несколько type-аргументов — через существующий `Expr.tuple`, не через изменение arity `Index_Expr`

**Rationale**: `Index_Expr` несёт единственный `index: ExprId`
(`ast.zig:245-249`). Расширение до списка потребовало бы менять форму
узла и ВСЕ 9 его потребителей (`type_checker.zig` — inferIndex,
checkAssignmentTarget; `compiler.zig` ×2; `mir_lowering.zig` ×4;
`resolver.zig` ×1) ради arity, которая нужна только этой фиче.
`Expr.tuple{elements: []const ExprId}` (`ast.zig:227-230`) уже
существует, уже парсится через `(a, b, ...)` — `ф[(A, B)](...)`
получает `Index_Expr{ index: Tuple_Expr{elements: [A, B]} }` СЕГОДНЯШНЕЙ
грамматикой. Одиночный `ф[Тип](...)` не заворачивается в кортеж —
`index` сам по себе один из type-шейп-форм.

**Alternatives considered**: менять `Index_Expr` на список — отклонено
(9 файлов ради arity, которая нужна только здесь); отдельный явный
синтаксис только для multi-arg (напр. другой токен) — отклонено, два
разных синтаксиса для одной фичи хуже одного (`(a,b)`-обёртки), не
lучше.

## Decision: Expr → TypeId напрямую, без синтезирования фейкового `TypeNode` в дереве

**Rationale**: `resolveType(self, type_node: ast.TypeId)`
(`type_checker.zig:4824`) — уже существующий резолвер `ast.TypeId ->
types.TypeId`, переключается по `self.tree.typeNode(type_node).*`
(`.ident`/`.generic`/`.qualified`/`.tuple`/`.function`), использует
`findGenericParameter`/`builtinType`/`findTypeSymbol`/`nominalType`/
`findQualifiedTypeSymbol`. У нас нет РЕАЛЬНОГО `ast.TypeId` для
`Index_Expr`'s `index`-поддерева (это `Expr`, не `TypeNode`) —
добавлять синтетический узел в `Ast` в середине тайпчека means
мутировать структуру, которая везде трактуется как read-only после
парсинга (`self.tree: *const ast.Ast` в `Checker`). Вместо этого —
параллельная функция `resolveTypeFromExpr(self, expr: ast.ExprId)
!?types.TypeId`, переключается по `self.tree.expr(expr).*`, обрабатывает
ТОЛЬКО `.ident`/`.property`/`.call` (остальные формы — `null`, не
типовидны), переиспользует ТЕ ЖЕ helper'ы, что `resolveType` уже
вызывает — не дублирует логику поиска символа/nominal-инстанциации,
только точку входа (Expr-форма вместо TypeNode-формы).

Отображение форм:
| `Expr`-форма | Аналог `TypeNode` | Обработка |
|---|---|---|
| `.ident{name}` | `.ident{name}` | `findGenericParameter`/`builtinType`/`findTypeSymbol` — то же, что `resolveType`'s `.ident`-ветка. |
| `.property{object: .ident{module}, property: name}` | `.qualified{module_name, name}` | `findQualifiedTypeSymbol(module, name)` — то же, что `.qualified`-ветка. Требует, чтобы `object` сам был `.ident` (иначе не типовидно — вложенные property-цепочки длиннее одного уровня не поддержаны, паносовские модули не вкладываются). |
| `.call{callee: (.ident или .property, как выше), arguments}` | `.generic{name, parameters}` / `.qualified{..., parameters}` | Резолвит `callee` как имя типа (той же логикой), рекурсивно резолвит каждый `argument` через `resolveTypeFromExpr` (та же функция — обрабатывает вложенные generic-инстанциации, `Список(Коробка(Число))` и т.п.), затем `nominalType(symbol, arguments)`. |
| Всё остальное (`.number`, `.binary`, произвольные выражения) | — | `null` — не типовидно, вызывающий код обязан диагностировать (FR-007), не молча трактовать как обычный индекс. |

**Alternatives considered**: временно добавлять узел в `Ast` через
`tree.addType(...)` и переиспользовать `resolveType` как есть —
отклонено, требует мутабельного доступа к дереву в тайпчекере, которого
сегодня архитектурно нет (`*const Ast` everywhere), и создаёт AST-узлы
без исходного текста для них (сомнительно для error-recovery/IDE
tooling, которые ожидают реальные spans из исходника — у нас они И ТАК
есть на исходных `Expr`-узлах, только через другой accessor).

## Decision: точка входа — новая ветка `.index` в `inferCallExpected`'s callee-switch

**Rationale**: `inferCallExpected` (`type_checker.zig:3385`) — общая
точка входа для `ф(...)` и `модуль.ф(...)`. После builtin-проверок она
свитчит по форме `call.callee` (`type_checker.zig:4402`): `.property`
запускает цепочку method/interface-диспетчеризации
(`inferProcessMethod`/`inferPreludeEnumMethod`/`inferInterfaceCall`/
`inferGenericBoundInterfaceCall`/`inferMethodCall`/
`inferDefaultInterfaceMethodCall`), `else` (в т.ч. сегодня — `.index`)
падает в общий путь `callee_type = try self.infer(call.callee)` →
`.function`-ветка (~4517), которая сама читает
`self.resolution.expr_symbols.get(call.callee)` и
`generic_function_parameters.get(symbol)`, строит `substitutions` из
аргументов/`expected_return`.

Новая `.index` ветка ПЕРЕД этим общим путём: если `index.object`
резолвится (`self.resolution.expr_symbols.get(index.object)`) в символ
с непустыми `generic_function_parameters` — это explicit-generic вызов,
не обычная индексация. Извлечь explicit type-выражения (одиночный
`index.index`, либо `.tuple.elements`, если это кортеж), резолвить
каждое через `resolveTypeFromExpr`; если что-то вернуло `null` —
FR-007 диагностика. Иначе — построить `substitutions`-карту, ЗАСЕЯННУЮ
явными значениями (`parameter.typ -> resolved_type` для каждого
`generic_parameters[i]` по объявленному порядку — FR-002/FR-003, длина
должна совпасть), и вызвать ОБЩУЮ логику `.function`-ветки (~4517-4700),
рефакторенную в отдельный helper, принимающий callee-выражение
(`index.object` вместо `call.callee`) и ПРЕДЗАСЕЯННУЮ
`substitutions`-карту вместо пустой.

Когда `index.object` НЕ резолвится в generic-функцию — не
реинтерпретировать вообще, отдать управление уже существующему общему
пути без изменений (FR-006, ноль регрессии для "индекс массива функций,
потом вызов").

## Decision: конфликт explicit-vs-inferred ловится БЕСПЛАТНО существующим `inferGenericSubstitution`

**Rationale**: `inferGenericSubstitution` (`type_checker.zig:5917`)'s
`.generic_parameter`-ветка УЖЕ обрабатывает случай "substitution для
этого параметра уже есть в карте, новый аргумент с ним не совпадает" —
`if (!self.assignable(argument, existing) or !self.assignable(existing,
argument)) try self.report(span, "Type Error: type-параметр выведен
неоднозначно", .{})` (строки 5945-5947). Если `substitutions`
предзасеяна explicit-значением ДО того, как обычный цикл вывода из
аргументов (`for (arguments[0..shared], function.parameters[0..shared])
|argument, parameter| try self.inferGenericSubstitution(...)`,
~4550-4552) пройдётся по аргументам — конфликт обнаруживается этим уже
существующим кодом, без единой новой строчки. FR-004 закрывается
бесплатно, просто порядком заполнения карты.

**Alternatives considered**: писать отдельную explicit-vs-inferred
проверку до/после существующего цикла — отклонено, дублирует логику,
которая уже корректно работает для двух РАЗНЫХ inferred-аргументов
одного параметра (тот же класс конфликта).

## Decision: метод-вызовы (`это.метод[Тип](...)`) — во вторую очередь, не в MVP-фазе plan'а

**Rationale**: свободные/квалифицированные функции идут через один
центральный путь (`inferCallExpected`'s callee-switch, `.index`-ветка
выше). Метод-вызовы (`это.метод(...)`) резолвятся структурно, ЧЕРЕЗ
`object_type` метода-получателя (`inferMethodCall`,
`type_checker.zig:5427`), не через `expr_symbols.get(call.callee)` —
`call.callee` там `.property`, а не `.index`, потому что синтаксис
`это.метод[Тип](...)` даёт СОВСЕМ ДРУГОЕ дерево:
`Call_Expr{ callee: Index_Expr{ object: Property_Expr{object: это,
property: "метод"}, index: Тип } }` — `.property`-ветка callee-switch'а
(4402) уже перехватывает ЛЮБОЙ `.property`-callee ДО того, как дошло
бы до `.index`, так что метод-случай физически не проходит через ветку
для функций. Метод-generic-explicit-args требует ОТДЕЛЬНОЙ точки
интеграции внутри `inferMethodCall` (сам метод должен научиться
принимать явно засеянные substitutions), структурно похожей, но не
идентичной. Меньше уверенности в деталях (не вычитано так же глубоко,
как путь свободных функций) — вынесено в Phase 2 plan'а, не блокирует
MVP (US1/US2 из spec.md сформулированы про функции, метод — Edge
Case, явно не блокирующий).

## Открытые вопросы для plan.md (не решены здесь, для проверки перед кодом)

- Существующий тест-набор на `nominalType`/`findQualifiedTypeSymbol`
  поведение при ошибке (не найден символ) — обе функции сегодня либо
  `null`, либо репортят диагностику САМИ (`resolveType`'s `.ident`
  ветка репортит "неизвестный тип"). `resolveTypeFromExpr` должна
  решить: репортить диагностику САМА при "похоже на тип, но символ не
  найден" (тогда `null` из неё означает ИСКЛЮЧИТЕЛЬНО "форма не
  типовидна", отдельно от "тип не найден") — сверить с FR-007's
  формулировкой ("нетиповидная форма" — другая диагностика, чем
  "неизвестный тип").
