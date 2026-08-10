# Language Compatibility Contract

## Function values

A value of functional type can be used where another functional type is expected only when arity, every parameter type, and result type are structurally identical. A function returning `Никогда` may replace a function with the same parameters and any result type.

## Generic interface bounds

For `T: A + B`, every call-site argument must implement both bounds. Inside the generic function, methods declared by either bound are callable. If two bounds expose the same method name, resolution follows the first declared matching bound; duplicate identical bounds are a Type Error.

`Сравниваемое` continues to use its existing comparison behavior and can coexist with user-defined bounds.

## Named calls

Named arguments are supported for declared free functions, spawn calls to such functions, structure constructors, and concrete inherent methods, including imported declarations. All arguments are mandatory, names are unique, and positional/named forms cannot be mixed.

Named arguments are rejected during type checking for enum constructors, interface-dispatched calls, generic bound-interface calls, function values/lambdas, builtins, collection/prelude methods, FFI calls, and any other call without declared parameter-name metadata.

## Assignment

Only mutable local variables, fields, array indexes, and map indexes are writable. String indexing is read-only.
