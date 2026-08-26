# Implementation Plan: Нативный host-function registry для `внешний "хост"`

**Branch**: `017-native-host-function-registry` | **Date**: 2026-08-26 | **Spec**: `specs/017-native-host-function-registry/spec.md`
**Input**: Feature specification from `specs/017-native-host-function-registry/spec.md`

## Summary

Сегодня `внешний "хост" функ ...` (единственный способ вызвать движок из
panos-скрипта) требует от встраивающего приложения `pub export fn` +
`rdynamic` и всегда идёт через `dlopen(NULL)`/`dlsym` + libffi
`ffi_prep_cif`/`ffi_call`, даже когда реальная сигнатура известна Zig-
компилятору движка на этапе его собственной сборки. Фича добавляет
альтернативный источник резолва — `comptime`-регистрируемую таблицу
`имя → Zig-функция`, передаваемую в `Runtime.Config.host_functions` —
и альтернативный путь вызова — прямой Zig-вызов через
`comptime`-сгенерированный type-erased trampoline на функцию, минуя
libffi полностью. `.pns`-синтаксис не меняется; старый `pub export fn`-
путь остаётся рабочим fallback'ом (ноль регрессии).

## Technical Context

**Language/Version**: Zig 0.16.0 (см. `AGENTS.md`, `minimum_zig_version`)
**Primary Dependencies**: без новых внешних зависимостей — переиспользует
существующие `ast_types.ForeignMarshalKind`, `bytecode.zig`,
`resolver.zig`, `vm.zig`, `zig/embed.zig`. libffi/`ffi_bindings.zig`
остаются нужны ТОЛЬКО для существующего dynlib-пути (не убираются).
**Storage**: N/A
**Testing**: `zig build test` (unit), `zig build integration`
(FFI/`внешний`-специфичные интеграционные тесты, куда добавляется новый
сценарий), расширение `tests/embed_host_test.zig` новыми кейсами (registry
happy-path, signature mismatch, registry+dlsym coexistence).
**Target Platform**: native (macOS/Linux/Windows) — тот же
`target_profile == .native` guard, что весь остальной `внешний`; не
затрагивает wasm32-freestaning (browser) сборку.
**Project Type**: library (panos как встраиваемый в другие Zig-приложения
рантайм) — расширение `panos_embed`-модуля.
**Performance Goals**: вызов зарегистрированной host-функции не должен
проходить через `ffi_prep_cif`/`ffi_call` (SC-003) — качественная, не
количественная цель на этом срезе; конкретный числовой бюджет (ns/вызов)
не зафиксирован в spec.md и не нужен для этой фичи (мотивирующий сценарий
— "десятки вызовов на кадр", уже безопасно на порядки дешевле генерального
libffi-пути одним фактом отсутствия `ffi_call`).
**Constraints**: обратная совместимость `внешний "хост"` (FR-007) —
жёсткое ограничение, не предмет компромисса. `.pns`-грамматика не
меняется.
**Scale/Scope**: типичный набор host-функций одного игрового движка —
низкие десятки записей в `host_functions`; не рассчитано и не должно
проектироваться под сотни/тысячи (не тот сценарий использования).

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- **I. Think Before Coding** — PASS. Открытый вопрос из spec.md
  (форма API регистрации) разрешён явно в `research.md` (Decision +
  Rationale + Alternatives considered), не выбран молча.
- **II. Simplicity First** — PASS с одной оговоркой. Comptime-генерация
  per-функции trampoline — не самое короткое возможное решение (проще
  было бы просто прокидывать `fn_ptr` и использовать тот же
  `ffi_call`-путь для всех "хост"-функций) — см. Complexity Tracking
  ниже за обоснование, почему более простая альтернатива не отвечает
  явным FR (FR-006, SC-003). Marshal-kind набор НЕ расширяется — держит
  фичу настолько узкой, насколько позволяют её собственные FR.
- **III. Surgical Changes** — PASS. Изменения ограничены точками,
  перечисленными в `data-model.md` (`bytecode.ForeignFunctionConstant`,
  `resolver.resolveForeignFunction`, `vm.invokeForeign`, новый
  `hostFunctions`/`HostFunctionEntry` в `zig/embed.zig`) — существующий
  `.dynlib_libffi`-код не рефакторится, только получает соседнюю ветку.

*Post-Phase-1 re-check*: не выявлено новых нарушений при детализации в
`data-model.md`/`contracts/` — `ForeignFunctionConstant` расширяется
дополнительными полями (не переписывается), `Resolver`/`Vm` получают
ветвление по `call_kind` (не замену существующей логики). PASS.

## Project Structure

### Documentation (this feature)

```text
specs/017-native-host-function-registry/
├── plan.md              # этот файл
├── research.md          # Phase 0 — архитектурная вычитка + решение по API-форме
├── data-model.md         # Phase 1 — HostFunctionEntry, расширения bytecode/resolver/vm
├── quickstart.md          # Phase 1 — минимальный рабочий пример
├── contracts/
│   └── embed-api.md       # Phase 1 — публичный контракт panos_embed после фичи
└── tasks.md               # Phase 2 (/speckit.tasks) — НЕ создаётся этой командой
```

### Source Code (repository root)

Не отдельный проект — расширение существующего `panos`-репозитория
(single-project структура, `zig/core/` + `zig/embed.zig`):

```text
zig/
├── core/
│   ├── bytecode.zig        # ForeignFunctionConstant: + call_kind, native_call
│   ├── resolver.zig        # resolveForeignFunction: + поиск в host_registry перед dlopen/dlsym
│   └── vm.zig               # invokeForeign: + ветка .native_registry (без libffi)
├── embed.zig                 # + HostFunctionEntry, hostFunctions(), Config.host_functions
└── cli/, lsp/, browser/       # без изменений (host registry — только embed-путь,
                                 # CLI/LSP/browser не встраивают Zig-хост)

tests/
└── embed_host_test.zig        # + сценарии: registry happy-path, signature mismatch,
                                  # registry+dlsym coexistence (приоритет registry)
```

**Structure Decision**: расширение существующих файлов на месте (не новые
модули верхнего уровня, кроме, возможно, выноса `HostFunctionEntry`/
`hostFunctions` в отдельный `zig/core/host_registry.zig`, если
`zig/embed.zig` разрастётся — решается в `tasks.md`/на реализации,
архитектурно не обязательно).

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| Per-функция `comptime`-generated trampoline вместо простого хранения `fn_ptr` + переиспользования существующего libffi-пути для ВСЕХ "хост"-вызовов | FR-006/SC-003 явно требуют, чтобы registry-вызов не шёл через `ffi_prep_cif`/`ffi_call` — это основная заявленная ценность фичи (см. `research.md`, "Оверхед на горячих путях"), не опциональная оптимизация | Простое хранение `fn_ptr` + существующий `ffi_call`-путь для "хост" ничем не отличалось бы от уже работающего `dlsym`-пути — решало бы только User Story 1 (не нужен `pub export fn`/`rdynamic`), но НЕ решало бы User Story 3 (оверхед на горячих путях), которая явно входит в scope spec.md |
