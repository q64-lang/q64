# q64-lsp

The q64 language server, its editor clients, and the WebAssembly build of
the q64 analysis core they all run on.

> **Status: diagnostics + hover/definition.** The core runs the full
> `q64 check` pipeline (parse + sema → LEX/PAR/NAM/TYP/EFF/REG), so the editor
> sees the same semantic diagnostics the compiler does — not just parse errors.
> Hover and go-to-definition work for top-level symbols and locals (params,
> `let`/pattern bindings); functions hover with their full signature. Still
> pending: field/member hover (needs the type checker) and formatting (`fmt`)
> in [`../q64`](../q64).

## Why this exists

A language server is two layers at very different altitudes:

| Layer | Work | Lives in |
|---|---|---|
| **Analysis core** | parse → typecheck → effect/region → diagnostics | [`../q64`](../q64) (Zig), compiled here to wasm |
| **Server shell** | JSON-RPC, document store, map results → LSP types | `packages/server` (TypeScript) |

The analysis core is **never reimplemented** — `packages/core-wasm` compiles
q64's existing Zig modules to a single `q64-core.wasm`. The TypeScript server
loads that wasm and speaks LSP. One core, every host: Node (desktop editors),
a browser Web Worker (vscode.dev, the qubepods editor), or a Cloudflare
Worker.

## No credentials, ever

This is a public, open-source repo. The language server is **pure offline
analysis** — no network, no tokens, no secrets. It only sees the buffers the
host hands it. Any cross-qube resolution that needs the Continuum is done by
the *host* via injected, unauthenticated callbacks; the server never holds
credentials. The only secret anywhere near this tree is the VSCode marketplace
publish token, which lives in CI, not in the repo.

## Layout

```
packages/
  core-wasm/   Zig analysis core → q64-core.wasm + TS bindings
  server/      LSP server (vscode-languageserver), host-agnostic
  vscode/      thin VSCode extension (vscode-languageclient)
test/          black-box suite — spawns the built server, speaks LSP
```

`test/` is deliberately **outside** the `packages/*` workspace glob: it is a
black-box consumer and can only reach the server the way a real client does
(launch it, speak the protocol), never by importing internals.

## Build

```sh
pnpm install
pnpm -C packages/core-wasm build   # zig → q64-core.wasm
pnpm -r build                      # build server + vscode
pnpm -C test test                  # black-box conformance
```
