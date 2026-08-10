# Implementation Plan: Sound Type Checking

**Branch**: `011-fix-type-soundness` | **Date**: 2026-08-10 | **Spec**: [spec.md](./spec.md)  
**Input**: Feature specification from `specs/011-fix-type-soundness/spec.md`

## Summary

Close four type-soundness gaps without broad language changes: make function signatures invariant, reject non-writable assignment targets during type checking, make named calls deterministic and early-diagnosed, and represent all non-comparable interface bounds of a generic value in one runtime interface package containing multiple vtables. The package carries an explicit vtable selector for each bound-method call; `Сравниваемое` remains its existing dispatch mechanism and unwraps the package before comparison.

## Technical Context

**Language/Version**: Zig 0.16.0; Panos source language  
**Primary Dependencies**: Zig standard library; existing bytecode VM and module compiler  
**Storage**: N/A  
**Testing**: Zig unit tests, `runner.zig` e2e, module compiler tests, conformance and AOT/browser build checks  
**Target Platform**: native CLI and `wasm32-freestanding` browser build  
**Project Type**: interpreter/compiler  
**Performance Goals**: no measurable regression for ordinary single-interface casts and calls; multi-bound casts allocate one wrapper per value conversion  
**Constraints**: preserve single-bound and `Сравниваемое` behavior; no monomorphization; no runtime compiler errors for statically unsupported named calls; vtable and method indexes remain within existing `u16` limits  
**Scale/Scope**: `type_checker`, bytecode compiler, VM value/GC paths, module import metadata, language documentation, and focused regressions

## Constitution Check

| Principle | Result | Evidence |
|---|---|---|
| Think Before Coding | Pass | Research resolves function compatibility, named-call scope, and multi-vtable representation before implementation. |
| Simplicity First | Pass with tracked complexity | Multi-vtable packaging is required by the requested multiple bounds; it replaces the unsafe single-vtable assumption rather than adding a general type-erasure system. |
| Surgical Changes | Pass | Work is limited to type metadata, bytecode/VM dispatch, named-call ordering, diagnostics, docs, and direct tests. |

## Project Structure

### Documentation (this feature)

```text
specs/011-fix-type-soundness/
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
└── contracts/
    └── language-compatibility.md
```

### Source Code (repository root)

```text
zig/core/
├── type_checker.zig      # compatibility, casts, named calls
├── compiler.zig          # vtable constants and ordered calls
├── bytecode.zig          # multi-vtable cast and selected interface call
├── value.zig             # interface package representation
├── gc.zig                # interface package lifecycle/marking
├── vm.zig                # cast, dispatch, copying, comparisons
├── module_compiler.zig   # imported method parameter-name metadata
├── mir_lowering.zig      # AOT handling of already supported named structs
└── runner.zig            # end-to-end regressions
docs/src/language/
└── functions.md          # exact named-argument contract
```

**Structure Decision**: Extend the existing interpreter pipeline at each ownership boundary; no new subsystem or project directory.

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|---|---|---|
| Runtime interface package with multiple vtables | A value under `T: A + B` must dispatch methods from both contracts safely. | Rejecting multiple bounds contradicts the requested language capability; sequential wrappers cannot identify the requested vtable and conflict with existing runtime representation. |

## Implementation Outline

1. Define the runtime/type-checking contract in `contracts/language-compatibility.md`; preserve supported named calls and list intentional early rejections.
2. Replace functional assignability with invariant parameter and result matching, retaining only the safe `Никогда` result exception with identical parameter lists.
3. Validate assignment targets by their inferred container/type, rejecting string indexing and non-addressable write forms before compiler/VM execution.
4. Replace a single generic-bound interface cast with an ordered multi-vtable cast package. Record which package slot each generic interface method call uses.
5. Change bytecode constants, interface value storage, GC/deep-copy handling, VM cast and dispatch to use the package; unwrap it for existing comparable operations.
6. Reorder named arguments for local and imported concrete methods before inference and codegen. Reject named enum, interface, generic-bound-interface, builtin, collection, FFI, lambda, and function-value calls when names cannot be defined reliably.
7. Make AOT named struct constructors consume the existing ordered-argument metadata rather than rejecting a documented form.
8. Add focused checker/compiler/VM/module/e2e tests and run the required project validation matrix.
