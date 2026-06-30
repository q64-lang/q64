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

## Coverage

- `initialize` capabilities (full text sync, diagnostics).
- `publishDiagnostics`:
  - clean source → none; empty buffer → none (zero-length input path);
  - `\r` → `LEX010` (lexer);
  - `@realtime + @io` fn → `EFF120` — a *semantic* code, proving the sema
    passes (not just the parser) are wired into the wasm core.
- document lifecycle: `didChange` re-validates the buffer; `didClose` clears.
- positional queries: `hover` over a function renders its full signature
  (`pub fn add(a: i64, b: i64) -> i64`; null on a keyword); `definition` jumps
  from a use to the declaration's range (null on a non-identifier). Locals too
  — a parameter and a `let` use each render `local <name>` and jump to their
  binding site.
- document symbols: the outline lists every top-level declaration in order
  with its LSP `SymbolKind` (empty list for an empty buffer).
- completion: offers in-scope symbols (right `CompletionItemKind`), the
  enclosing function's params + `let` bindings, plus the language keywords; an
  empty buffer still offers the keywords.

As the server grows formatting / locals support, add cases here against the
same black-box transport.
