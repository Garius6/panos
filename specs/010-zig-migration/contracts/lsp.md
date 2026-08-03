# LSP Compatibility Contract

## Transport

`panos-lsp` communicates by JSON-RPC over stdin/stdout using standard LSP
message framing. Stdout contains protocol messages only; logs and diagnostics
about server internals go to stderr.

## Required methods

The server advertises and handles the following existing methods:

| Group | Methods |
|-------|---------|
| Lifecycle | `initialize`, `textDocument/didOpen`, `textDocument/didChange`, `textDocument/didClose` |
| Navigation | `hover`, `definition`, `references`, `prepareRename`, `rename`, `documentHighlight`, `workspace/symbol` |
| Editor support | `completion`, `signatureHelp`, `semanticTokens/full`, `foldingRange`, `documentSymbol`, `codeLens`, `selectionRange` |

## Document semantics

- Each open document has a graph built with all currently open unsaved-source
  overrides.
- Published diagnostics include parser, resolver and type checker findings
  from the document graph, in LSP positions matching the source bytes.
- Rename and references retain the existing documented limit: current graph
  plus currently open documents; closed reverse dependents on disk are not
  required.
- Invalid requests, missing documents and invalid positions receive a valid
  JSON-RPC/LSP error or empty result; they never terminate the server.

## Transcript verification

Every required method has a success and an invalid-input transcript. A
transcript asserts response method/result shape, document edits, source
ranges, diagnostics and absence of non-protocol stdout.
