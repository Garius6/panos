# Data Model: Sound Type Checking

## Function compatibility

| Field | Rule |
|---|---|
| Parameter count | Must match exactly. |
| Parameter type | Must match structurally at every position. |
| Return type | Must match structurally, except `Никогда` is compatible with any expected return when parameters match. |
| Poison | Retains diagnostic recovery only; it must not establish a broad function-subtyping relation. |

## Assignment target

| Target shape | Writable | Validation |
|---|---:|---|
| Mutable local variable | Yes | Resolver confirms variable is not const. |
| Structure field | Yes | Field exists and replacement matches field type. |
| Array index | Yes | Index is numeric and replacement matches element type. |
| Map index | Yes | Key and replacement match map types. |
| String index | No | Type Error before code generation. |
| Any other expression | No | Type Error before code generation. |

## Interface package

| Field | Meaning | Invariant |
|---|---|---|
| receiver | Original concrete aggregate or enum value | Never another interface package. |
| vtables | Ordered method-table collection for non-comparable bounds | One entry per distinct declared user-interface bound. |
| vtable slot | Index recorded by a generic-bound method call | Refers to the bound's declaration order. |
| method index | Index within the selected interface's methods | Valid for the selected vtable only. |

State transition: a concrete value becomes one interface package at generic-call entry; it remains packaged through generic forwarding; an interface call selects the required table; a comparable operation unwraps `receiver` and follows existing comparable dispatch.

## Named call metadata

| Field | Meaning |
|---|---|
| source arguments | Expressions in user-written order. |
| parameter names | Names from a declared free function or concrete method, including imported declarations. |
| ordered arguments | Expressions stored in declaration order for inference and all code generators. |
| unsupported-name reason | Type Error when no authoritative parameter-name contract exists. |
