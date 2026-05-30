# q64-lsp test

Black-box conformance suite for the q64 language server.

It spawns the **built** server exactly as an editor does
(`node ../packages/server/dist/node.js --stdio`) and speaks LSP over
stdio. It imports nothing from the workspace — the only thing under test is
the wire contract. That is why this folder sits *outside* the `packages/*`
workspace glob.

## Run

```sh
# from q64-lsp/: build the core + server first
pnpm -C packages/core-wasm build
pnpm -C packages/server build
# then:
pnpm -C test test
```

Point at a different server build with `Q64_LSP_SERVER=/path/to/server.js`.

## Coverage (v0)

- `initialize` capabilities (full text sync, diagnostics).
- `publishDiagnostics`: clean source → none; `\r` → `LEX010`.

As the server grows hover/definition/formatting, add cases here against the
same black-box transport.
