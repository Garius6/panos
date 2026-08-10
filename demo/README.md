# Panos demos

Each directory is an independent, small project. From the repository root,
run a CLI example with `./panos <path-to-main.ps>`.

| Project | Shows | Run |
| --- | --- | --- |
| `01-language-tour` | structures, enums, `выбор`, arrays and maps | `./panos demo/01-language-tour/main.ps` |
| `02-modules-and-generics` | file imports, exported types and a bounded generic function | `./panos demo/02-modules-and-generics/main.ps` |
| `03-processes` | isolated state in a process and typed messages | `./panos demo/03-processes/main.ps` |
| `04-aot-imports` | local files linked into one AOT WASM module | `zig-out/bin/panos build --target=wasm demo/04-aot-imports/main.ps` |
| `dom` | a browser counter compiled to WASM | open `demo/dom/counter.html` through a local web server |
| `todo-app` | full-stack todo application: Panos HTTP backend plus WASM/DOM frontend | see `todo-app/` |

Build the CLI first when needed:

```sh
zig build
```

The first three examples deliberately avoid external services and use only
the language runtime, so they are suitable as a quick smoke test.
