# LSP-сервер

## Что

`panos-lsp` — отдельный бинарник (`lsp/main.odin`, собирается через
`just build-lsp`, см. [тулчейн и тестирование](./toolchain-and-testing.md)),
общается с редактором по JSON-RPC через stdin/stdout (`lsp/lsp_transport.odin`).

**`LSP_Document`** (`lsp/lsp_server.odin:17`) — состояние одного открытого
документа: `uri`/`path`/`source`, `file_id: u16`, **`graph: core.Module_Graph`**
(граф импортов, построенный ИМЕННО для ЭТОГО документа — не общий на весь
проект), `prog: core.Program`, **`res_ctx: core.Resolver_Ctx`** (поле-значение,
не указатель — для передачи в функции `core`, ожидающие `^Resolver_Ctx`, нужно
брать `&doc.res_ctx`), `tc_ctx: core.Type_Ctx`, `all_diagnostics` (diagnostics
со ВСЕХ модулей графа, не только entry-документа), `results: [dynamic]core.Module_Result`
(по каждому модулю графа), **`usages: map[core.Symbol_Id][dynamic]core.Span`**
(все места использования каждого символа во всём графе — построено
`build_usages`, используется find-references/rename/documentHighlight/codeLens).

**`LSP_Server`** — `{documents: map[string]^LSP_Document}`.

Реализованные методы (`lsp/lsp_server.odin`, dispatch по `envelope.method`):
`initialize`, `textDocument/didOpen`/`didChange`/`didClose`, `hover`,
`definition`, `completion`, `references`, `prepareRename`/`rename`,
`semanticTokens/full`, `documentHighlight`, `foldingRange`, `documentSymbol`,
`signatureHelp`, `workspace/symbol`, `codeLens`, `selectionRange`.

Протокольный слой — `lsp/protocol/lsp_types.odin`, **автогенерирован**
(`Generated from LSP metaModel.json 3.17.0 by generate.py. Do not edit by
hand.`) из `Garius6/odin-lsp-protocol` через `just sync-lsp-protocol`
(см. [тулчейн и тестирование](./toolchain-and-testing.md)) — правки в
этот файл руками теряются при следующей синхронизации.

## Зачем

LSP-сервер — отдельный бинарник, а не режим работы основного
интерпретатора, потому что у него принципиально другой жизненный цикл:
живёт весь сеанс редактирования, держит состояние МНОЖЕСТВА открытых
документов одновременно, отвечает на запросы позиции курсора (hover/
definition/completion), а не просто выполняет программу от начала до
конца. При этом он ПЕРЕИСПОЛЬЗУЕТ пайплайн `core` целиком (резолвер,
тайпчекер) — не дублирует логику анализа кода, только оборачивает её в
протокол JSON-RPC и добавляет свои LSP-специфичные вычисления (semantic
tokens, folding ranges и т.п. — см. `core/semantic_tokens.odin`,
`core/folding_ranges.odin`, `core/document_symbols.odin`,
`core/signature_help.odin`, `core/selection_range.odin` — эти файлы живут
в `core`, не в `lsp/`, ровно потому что переиспользуют внутренние типы
`core` напрямую, без публичного API-барьера).

## Почему так, а не иначе

**Граф импортов — НА ДОКУМЕНТ, не на проект**: `update_document`/
`revalidate_document` вызывают `core.load_module_graph_with_overrides(doc.path, overrides)`
для КАЖДОГО документа отдельно, где `overrides` — тексты всех СЕЙЧАС
ОТКРЫТЫХ документов (несохранённые правки редактора подставляются вместо
чтения с диска). Следствие: `doc.graph` содержит ТОЛЬКО прямые импорты
ЭТОГО документа — не "кто импортирует этот документ" (reverse-dependents).

**`Symbol_Id` НЕ сравним между графами разных документов** — раз у каждого
документа СВОЙ `Module_Graph` со СВОИМ `Symbol_Store` (см.
[резолвер](./resolver.md) про то, что `Symbol_Store` общий на ВЕСЬ
граф, но граф — уже НЕ общий на проект в LSP), один и тот же файл,
загруженный в графы ДВУХ разных открытых документов, получает РАЗНЫЕ
`Symbol_Id` в каждом. Найдено и исправлено (rename/references, коммит
`8fd91bd`): чтобы rename/references видели usages в файлах, ИМПОРТИРУЮЩИХ
текущий документ (а не только в файлах, которые он сам импортирует),
`merge_cross_document_usages` сопоставляет декларацию МЕЖДУ графами по
(путь файла, byte-span объявления), а НЕ по `Symbol_Id` — span объявления
идентичен байт-в-байт в обоих графах (если файл не менялся), а `Symbol_Id`
— нет.

## Известные ограничения

- **rename/references видят только: (1) граф импортов ТЕКУЩЕГО документа,
  (2) usages в ДРУГИХ СЕЙЧАС ОТКРЫТЫХ документах** (через
  `merge_cross_document_usages`) — НЕ весь проект на диске. Файл, который
  импортирует текущий документ, но не открыт в редакторе, не будет найден.
  Требуется project-wide reverse-import индекс (файловый обход + лёгкий
  парсинг `импорт`-строк без полного резолва) — не реализовано.
- **`workspace/symbol`** — та же граница: агрегирует
  `compute_document_symbols` по всем СЕЙЧАС ОТКРЫТЫМ документам, не по
  всему проекту на диске.
- **`documentHighlight`** — намеренно ограничен ОДНИМ документом (не как
  references/rename) — сама спека LSP не предполагает межфайловый scope
  для этого метода.

Отдельно от архитектурных ограничений выше — см.
[известные грабли](./known-pitfalls.md): оба ПОДТВЕРЖДЁННЫХ БАГА в этом
списке (сегфолт на `map[key]` в `for`-range, `json.marshal`/поля-указатели)
найдены именно в этом LSP-коде (`lsp/lsp_server.odin`) — не архитектурные
компромиссы, а реальные ловушки, в которые легко наступить снова при
следующей правке.

## Точки входа для типичной правки

| Изменение | Файл/функция |
|---|---|
| Новый LSP-метод | см. [рецепт](./recipes/new-lsp-method.md) |
| Изменить, что видит find-references/rename | `collect_locations`/`merge_cross_document_usages` (`lsp/lsp_server.odin`) |
| Изменить набор capabilities, объявляемых клиенту | `handle_initialize` (`lsp/lsp_server.odin`) |
| Обновить протокольный слой из новой версии LSP-спеки | `just sync-lsp-protocol` (тянет `lsp/protocol/lsp_types.odin` из `Garius6/odin-lsp-protocol`) — НЕ редактировать этот файл руками |
| Добавить LSP-специфичное вычисление, использующее внутренние типы `core` (по образцу semantic tokens/folding ranges) | новый файл в `core/` (не в `lsp/`) — переиспользует `Resolver_Ctx`/`Type_Ctx`/`Program` напрямую |
