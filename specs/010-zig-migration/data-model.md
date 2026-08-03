# Data Model: Zig implementation and compatibility corpus

## Source and diagnostics

### `Source_File`

| Field | Meaning | Validation |
|-------|---------|------------|
| `id` | Stable file identifier inside one module graph | Never reused while graph lives |
| `path` | User-visible logical path | Normalized before comparison |
| `bytes` | Immutable UTF-8 source bytes | Invalid UTF-8 produces diagnostic, never panic |

### `Span`

| Field | Meaning | Validation |
|-------|---------|------------|
| `file_id` | Owning source file | Must exist in graph |
| `start` | Inclusive byte offset | `0 <= start <= end` |
| `end` | Exclusive byte offset | `end <= source.bytes.len` |

### `Diagnostic`

| Field | Meaning |
|-------|---------|
| `phase` | Lexer, parser, resolver, type checker, compiler, runtime or LSP |
| `severity` | Error or warning |
| `message` | Russian user-facing description |
| `span` | Source location where applicable |

Diagnostics are append-only within a phase. A phase returns control after
recoverable errors; only internal invariant failures are fatal to the tool.

## Syntax and semantic graph

### `Token` and `Ast_Node`

Tokens reference `Span`; AST nodes are allocated in a per-analysis arena and
refer to children by stable node ID. Every node kind maps to exactly one
documented Panos construction. The parser never retains slices into mutable
editor input.

### `Module_Graph`

| Field | Meaning |
|-------|---------|
| `modules` | Canonical path → parsed module |
| `order` | Dependencies before importer |
| `sources` | `Source_File` collection |
| `prelude` | Implicitly reachable standard declarations |
| `diagnostics` | Loader/parser diagnostics from all modules |

State transitions: `loading` → `loaded` → `resolved` → `typed` → `lowered`.
An import reaching `loading` produces the existing controlled cycle diagnostic.

### `Symbol` and `Type`

`Symbol_Id` and `Type_Id` are graph-local opaque IDs. A `Symbol` records kind,
visibility, declaration span, canonical qualified name and typed payload. A
`Type` represents primitive, tuple, function, collection, nominal,
interface, generic parameter, instantiated generic or never type. IDs from
different module graphs, including different LSP documents, are never
compared directly.

### `Target_Profile` and `Builtin_Availability`

`Target_Profile` is `native`, `browser_interpreter`, `aot_js_wasm` or
`aot_wasi`. `Builtin_Availability` is `all`, `native_only` or
`aot_wasm_only`. A builtin call is valid only when both values agree.
Opaque resource methods carry the same profile validation in their native
adapter because they are not ordinary builtin calls.

`aot_wasm_only` denotes the current JS-hosted AOT surface (`DOM::*` and
sync HTTP); it is unavailable to `aot_wasi`, whose host ABI has no DOM/XHR
imports. `browser_interpreter` runs bytecode and therefore accepts only
`all`; it must reject AOT-only calls both statically and at its runtime
boundary.

## Execution model

### `Value` and `Heap_Object`

`Value` is a tagged union for immediate number, boolean, null/void, function
reference, process ID and reference to `Heap_Object`. `Heap_Object` begins
with a GC header and represents string, aggregate, array, map, error, option,
result, interface, variant, closure or native resource. Heap objects have
stable addresses for their entire lifetime.

### `Gc_Heap`

`Gc_Heap` owns all heap objects allocated by a VM instance. Collection is
mark-and-sweep and non-moving. Roots include VM frames/stacks, compiled
constant pools, globals, closures reachable from functions, actor mailboxes,
pending async results and explicitly pinned native resources. Workers exchange
only data transfer objects, never `Value` or heap pointers.

### `Function_Code`, `Frame` and `Process`

`Function_Code` contains bytecode instructions, constants, frame size,
return-value contract and debug source map. `Frame` references a function and
holds instruction pointer/locals. `Process` owns a frame stack, mailbox,
waiting state and pending async result slots. Scheduler transitions are
`runnable` → `waiting_async|waiting_receive` → `runnable` → `finished`.

### `Async_Completion`

| Field | Meaning |
|-------|---------|
| `process_id` | Target process, never a VM pointer |
| `operation` | Builtin/resource operation kind |
| `payload` | Data-only success value or failure metadata |

VM materializes `payload` as `Value` on its owning thread. Completion for a
finished process is discarded after releasing native payload resources.

## Tooling model

### `Lsp_Document`

An LSP document keeps URI, editable source version, a module graph built with
open-document overrides, diagnostics and computed symbol usages. Its symbols
remain document-graph local; cross-document operations correlate declarations
by canonical path and declaration span.

### `Conformance_Case` and `Outcome`

`Conformance_Case` contains ID, tier, profile, fixture/inline source,
arguments, controlled environment and expected `Outcome`. `Outcome` contains
status (`success`, `diagnostic`, `runtime_error`, `unsupported`, `external`),
stdout, normalized result, normalized diagnostics and optional approved
deviation. Details are defined in [contracts/conformance.md](./contracts/conformance.md).
