# Explicit Generic Call Resolution Contract

## Syntax

```text
callee '[' type-arg-list ']' '(' arguments ')'

type-arg-list := type-expr | '(' type-expr (',' type-expr)+ ')'
type-expr     := ident | ident '.' ident | type-expr '(' type-expr (',' type-expr)* ')'
```

No new tokens. `type-arg-list` parses through the EXISTING
`Index_Expr`/`Tuple_Expr` grammar — a single `type-expr` is an ordinary
`index`; multiple are an ordinary parenthesized tuple literal used as
the index.

## Resolution order (semantic phase, not parser)

1. `callee '[' X ']' '(' args ')'` parses unconditionally as
   `Call_Expr{ callee: Index_Expr{ object: callee, index: X } }` —
   IDENTICAL to today's "index then call" form.
2. Typechecker resolves `index.object`'s symbol. If it has NO generic
   parameters (`generic_function_parameters.get(symbol)` empty/absent),
   this call is NOT reinterpreted — ordinary index-then-call semantics
   apply, unchanged.
3. If `index.object`'s symbol DOES have generic parameters, `X` (or
   each element of `X` when it is a `Tuple_Expr`) MUST resolve via
   `resolveTypeFromExpr` to a concrete `TypeId`. A form that does not
   resolve (arithmetic, arbitrary calls, etc.) is a Type Error — this
   callee is a generic function, so `[...]` MUST be a type-argument
   list, not a value index.
4. The count of resolved type-expressions MUST equal the function's
   declared generic-parameter count, matched by DECLARATION ORDER —
   mismatch is a Type Error.
5. Each resolved type is seeded into the substitutions map for the
   corresponding parameter BEFORE ordinary argument-based inference
   runs. Ordinary inference (per-argument `inferGenericSubstitution`)
   then proceeds unchanged — a disagreeing inferred type against an
   already-seeded explicit one is caught by the EXISTING ambiguity
   check ("type-параметр выведен неоднозначно"), not a new mechanism.
6. Interface-bound checks on each substituted parameter run exactly as
   they do for a fully-inferred call — an explicit argument violating
   a declared bound is a Type Error, same diagnostic path.

## Non-goals of this contract

- Method calls (`это.метод[Тип](...)`) — different AST shape
  (`Index_Expr` over `Property_Expr`, intercepted earlier by the
  `.property`-callee dispatch chain before reaching this resolution
  path) — separate, deferred integration point (see plan.md's
  "Deferred" section).
- Generic-bound interface dispatch calls — not covered, behavior
  unspecified until researched separately.
- Enum/struct constructors — already typed via `Тип(Аргумент)` at the
  type level, not the call level; out of scope by definition.
