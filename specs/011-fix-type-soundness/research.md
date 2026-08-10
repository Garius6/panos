# Research: Sound Type Checking

## Decision: use invariant function signatures

**Rationale**: Current direct parameter assignability is unsafe. Full variance would also require runtime adapters: a covariant return can be a concrete value where later code expects an interface wrapper. Panos has no such adapters. Exact structural parameter and result equality is safe and minimal; a `Никогда` result remains assignable to any expected result with the same parameter list.

**Alternatives considered**:

- Contravariant parameters and covariant results: type-theoretically valid, but incomplete without runtime return casts/adapters.
- Preserve current recursive assignability: unsound for interface parameters and results.

## Decision: package all generic user-interface vtables atomically

**Rationale**: A generic value with `T: A + B` must retain both dispatch tables. One wrapper holds the raw receiver and vtables in declaration order; every compiled generic-bound interface call carries the selected table index and method index. This preserves compiled-once generics and avoids nested/overwritten wrappers.

**Alternatives considered**:

- Use only the first bound: current unsafe behavior; methods from another bound use the wrong vtable.
- Apply multiple sequential casts: a wrapper only accepts an aggregate today; nested wrapping adds ambiguous dispatch and copying/GC complexity without solving selection.
- Monomorphize generic functions: conflicts with the current generic execution model and broadens scope substantially.

## Decision: retain `Сравниваемое` outside the vtable package

**Rationale**: Its existing runtime lookup expects raw numeric or aggregate values. The VM must unwrap an interface package before comparable dispatch, allowing `T: Сравниваемое + Печатаемое` to compare and invoke the user-interface method.

**Alternatives considered**:

- Add `Сравниваемое` as a vtable: would replace separate established dispatch and is not required.
- Disallow mixed bounds: violates the supported multiple-bound feature.

## Decision: support named calls only where parameter names are contractually available

**Rationale**: Concrete declared methods have names and can reuse existing reorder metadata. Interface definitions and enum variants do not expose parameter/field names in current metadata, so accepting names would be ambiguous or fail late.

**Alternatives considered**:

- Extend interfaces and enum variants with names: separate language-design feature that expands cross-module interface metadata and public semantics.
- Keep late compiler rejection: violates the requirement to report unsupported forms during type checking.

## Decision: preserve named calls on imported concrete methods

**Rationale**: Importing a method must not alter its source-language calling contract. Carry parameter names through existing import metadata rather than silently narrowing support to local types.

**Alternatives considered**:

- Reject imported named methods: surprising semantic difference across a module boundary.

## Decision: reuse ordered call arguments in AOT struct constructors

**Rationale**: Named struct constructors are documented language behavior. AOT must consume the same checked ordering rather than reject an otherwise valid source form.

**Alternatives considered**:

- Preflight-reject named structs for AOT: creates target-specific semantic divergence.
