# Известные грабли

Растущий список подтверждённых живым тестом ловушек — не гипотетические
проблемы, а реально воспроизведённые баги с известным исправлением.

### Прямая индексация `map[K][dynamic]V` внутри `for`-range на отсутствующем ключе — сегфолт

**Симптом**: процесс `panos-lsp` падает с segmentation fault (`exit 139`,
`SIGSEGV`) без единого diagnostic-сообщения в stderr.

**Причина**: код вида `for x in someMap[key] { ... }`, где `someMap` —
`map[K][dynamic]V` — при ОТСУТСТВУЮЩЕМ `key` приводит к сегфолту, если
map индексируется НАПРЯМУЮ внутри `for`-range clause (без предварительного
присваивания результата локальной переменной). Баг не проявлялся раньше,
потому что все существующие вызывающие (`textDocument/references`/
`rename`/`documentHighlight`) резолвили `Symbol_Id` ТОЛЬКО по клику на
реально существующее использование символа — значит ключ в
`doc.usages[sym_id]` гарантированно был. `textDocument/codeLens`
(см. [LSP-сервер](./lsp.md)) стал первым вызывающим, перебирающим ВСЕ
функции файла, включая НИКЕМ не вызываемые (0 usages, ключ отсутствует в
map) — и обнажил баг.

**Безопасный паттерн**: получить значение через двузначную форму map-доступа
СНАЧАЛА, потом ranging по локальной переменной:

```odin
// ПЛОХО — сегфолт на отсутствующем ключе:
for sp in doc.usages[sym_id] { ... }

// ХОРОШО:
usages_for_sym, _ := doc.usages[sym_id]
for sp in usages_for_sym { ... }
```

**Источник**: обнаружено и исправлено в коммите `85b6455` (панос,
`lsp/lsp_server.odin` — `collect_locations`, `merge_cross_document_usages`,
`handle_document_highlight`).

---

### `core:encoding/json.marshal` не поддерживает поля-указатели

**Симптом**: `json.marshal` возвращает ошибку `Unsupported_Type` для
структуры, содержащей поле-указатель (`^T`), вместо сериализации указанных
данных.

**Причина**: `proto.SelectionRange.parent: ^SelectionRange` — единственное
поле-указатель во ВСЁМ автогенерированном протокольном пакете
(`lsp/protocol/lsp_types.odin`) — понадобилось для рекурсивной цепочки
"expand selection" (`textDocument/selectionRange`). `core:encoding/json.marshal`
из стандартной библиотеки Odin не умеет маршалить структуры с полями-
указателями вообще — struct с таким полем не сериализуется через обычный
`send_response`, который передаёт значение напрямую в `json.marshal`.

**Безопасный паттерн**: для ответов, требующих рекурсивной/само-ссылающейся
структуры, собирать `json.Value` (`json.Object`/`json.Array`) ВРУЧНУЮ,
минуя struct-marshaling целиком:

```odin
// ПЛОХО — Unsupported_Type на поле-указателе внутри struct:
send_response(id, proto.SelectionRange{range = rng, parent = &parent_node})

// ХОРОШО — дерево json.Value вручную:
obj := make(json.Object)
obj["range"] = range_to_json_value(rng)
if has_parent {
    obj["parent"] = selection_range_chain_to_json(doc, deduped, idx + 1)
}
send_response(id, json.Value(obj))
```

**Источник**: обнаружено при реализации `textDocument/selectionRange`
(`lsp/lsp_server.odin` — `handle_selection_range`,
`selection_range_chain_to_json`, `range_to_json_value`,
`position_to_json_value`).

---

### Стековый композитный литерал вместо `new()` — dangling pointer, читаемый ПОЗЖЕ компиляции

**Симптом**: не проявлялось годами тихо (никакого явного краша) — данные,
прочитанные через `Symbol.module` (`^Module`) на этапе компиляции/
мономорфизации, оказывались мусором/устаревшими, если читались достаточно
поздно после возврата из функции, создавшей `Module`.

**Причина**: `resolve_program` (`core/resolver.odin:913`) создаёт
`module := new(Module)` (heap-аллокация) СОЗНАТЕЛЬНО, а не через стековый
композитный литерал `module := Module{...}` — раньше был именно стековый
вариант. Каждый созданный резолвером `Symbol` хранит `Symbol.module`
(`^Module`) и переживает саму `resolve_program` — он читается вплоть до
`compile_program`/`monomorphize_program` (`core/monomorphize.odin`).
Стековая версия давала dangling pointer, как только `resolve_program`
возвращалась — баг не всплывал годами, пока bounded traits' `monomorphize_one`
не стал ПЕРВЫМ кодом, читающим `Symbol.module` так поздно (на этапе
компиляции, стек уже многократно переиспользован другими вызовами).

**Безопасный паттерн**: любая структура, на которую другие данные хранят
`^T`-указатель и которая должна пережить функцию, её создавшую — heap-
аллокация через `new(T)`, НЕ стековый композитный литерал, даже если на
момент написания кода кажется, что указатель используется только локально.

**Источник**: комментарий в `core/resolver.odin:914-923` (тот же класс
бага отмечен и в `parse_for_range_stmt_into`, парсер, Стадия 32, для
`Целое`-индексов).
