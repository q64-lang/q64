# @q64/server

The q64 language server — the protocol shell over [`@q64/core-wasm`](../core-wasm).

It owns only what is *not* language intelligence:

- the LSP wire protocol (via `vscode-languageserver`),
- the open-document store and change tracking,
- mapping q64's diagnostic envelope to LSP `Diagnostic[]`.

All parsing/analysis is delegated to the wasm core. The server never reaches
the network and holds no credentials — it is pure local analysis.

## Hosts

`src/server.ts` wires the handlers to a **Node stdio** connection (desktop
editors, the VSCode extension). The same handlers can be mounted on a
browser/Worker connection for vscode.dev and the qubepods editor — only the
transport differs, because the analysis is the wasm.

## Capabilities (v0)

| Request | Status |
|---|---|
| `initialize` / `initialized` / `shutdown` | ✅ |
| `textDocument/didOpen` · `didChange` · `didClose` | ✅ (full sync) |
| `textDocument/publishDiagnostics` | ✅ (parse + sema check — LEX/PAR/NAM/TYP/EFF/REG) |
| hover · definition · formatting · code actions | ⏳ await positional query exports (`q64_hover`, …) + `fmt` in [`../../../q64`](../../../q64) |

## Run

```sh
pnpm build
node dist/server.js --stdio
```

Editors launch it with `--stdio`; the black-box suite in [`../../test`](../../test)
drives it the same way.
