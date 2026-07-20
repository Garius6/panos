# Рецепт: новый LSP-метод

Пример — по образцу уже реализованных методов
(`textDocument/documentHighlight`, `textDocument/foldingRange` и т.п. —
все в `lsp/lsp_server.odin`).

## Файлы по порядку (pipeline order)

1. `lsp/protocol/lsp_types.odin` — проверить, что нужные типы (Params/
   Result) уже существуют (см. ниже — почти всегда да)
2. `core/*.odin` — если метод вычисляет что-то НОВОЕ на основе AST/
   резолвера/тайпчекера (semantic tokens/folding ranges — стиль)
3. `lsp/lsp_server.odin` — capability, dispatch, сам handler

## Шаги

1. **Проверить типы протокола**: `lsp/protocol/lsp_types.odin` —
   **автогенерирован целиком** из LSP metaModel 3.17.0
   (`just sync-lsp-protocol`, см. [тулчейн и тестирование](../toolchain-and-testing.md)),
   нужные `*Params`/`*Options`/результат почти наверняка УЖЕ там (полная
   спека уже сгенерирована) — искать по имени метода. НЕ редактировать
   этот файл руками.

2. **Если метод нуждается в НОВОМ вычислении над кодом** (не переиспользует
   уже готовую логику hover/definition) — реализовать его в НОВОМ файле
   `core/*.odin` (не в `lsp/`), по образцу `core/semantic_tokens.odin`/
   `core/folding_ranges.odin`/`core/document_symbols.odin`/
   `core/signature_help.odin`/`core/selection_range.odin` — эти файлы
   напрямую переиспользуют внутренние типы `core` (`Resolver_Ctx`,
   `Type_Ctx`, `Program`, `Span`) без публичного API-барьера. Функция
   должна принимать уже посчитанные `res: ^Resolver_Ctx`/`tc: ^Type_Ctx`/
   `prog: Program` — НЕ выполнять резолв/тайпчек заново.

3. **Объявить capability**: `handle_initialize` (`lsp/lsp_server.odin:118`)
   — добавить поле в композитный литерал `proto.ServerCapabilities` (см.
   уже существующие `hover_provider`/`definition_provider` и т.п. — для
   методов с опциями типа `SignatureHelpOptions`/`CodeLensOptions`
   передаётся сама структура опций, не просто `true`).

4. **Зарегистрировать dispatch**: главный `switch envelope.method` в
   `lsp/lsp_server.odin` — добавить `case "textDocument/имяМетода":` (или
   `"workspace/имяМетода"` для workspace-методов), вызывающий новый
   `handle_имя_метода`.

5. **Написать handler**: `handle_имя_метода :: proc(server: ^LSP_Server, id: json.Value, params: json.Value)`
   — типичный паттерн: `decode_params(proto.ИмяParams, params)` →
   найти `doc, found := server.documents[uri]` → вызвать вычисление из
   шага 2 (или переиспользовать существующее, например
   `resolve_symbol_at_position` для методов, завязанных на позицию
   курсора) → `send_response(id, result)` или `send_null_response(id)`.
   **Внимание**: если ответ содержит поле-указатель (рекурсивная
   структура) — `json.marshal` его не поддержит напрямую, см.
   [известные грабли](../known-pitfalls.md).

6. **Известный класс бага при доступе к `doc.usages`/аналогичным map'ам**:
   если handler перебирает МНОЖЕСТВО символов (не один, найденный по
   позиции курсора) — прямая индексация `map[key]` внутри `for`-range на
   потенциально отсутствующем ключе сегфолтит, см.
   [известные грабли](../known-pitfalls.md) — использовать
   `v, ok := m[key]` перед циклом.

## Проверка

- `odin build ./lsp -out:panos-lsp` — чистая сборка.
- Ручной JSON-RPC-вызов через stdin/stdout: сформировать `initialize` →
  `initialized` → `textDocument/didOpen` → запрос нового метода, проверить
  корректный ответ (см. паттерн в `lsp/lsp_transport.odin` —
  `Content-Length`-заголовок + JSON-тело).
- Редеплой бинарника во все места, где он установлен локально для
  тестирования редактором (см. [тулчейн и тестирование](../toolchain-and-testing.md) →
  "Ритуал редеплоя").
