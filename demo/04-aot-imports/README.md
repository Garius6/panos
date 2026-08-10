# AOT imports

The WASM builder follows a local Panos import and links both functions into a
single `.wasm` module. This first AOT module-graph slice supports the same
numeric/control-flow MIR subset as the single-file builder.

```sh
zig build
zig-out/bin/panos build --target=wasm demo/04-aot-imports/main.ps -o /tmp/panos-aot-imports.wasm
```

The exported `старт` function returns `42`.
