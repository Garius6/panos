# Modules and generics

`main.ps` imports `математика.ps`. The imported module exports both a generic
structure and `большее[T: Сравниваемое]`; the call crosses a module boundary
while preserving the generic bound.

```sh
./panos demo/02-modules-and-generics/main.ps
```

Expected result: `42`.
