# q64-vscode

The q64 VSCode extension. A thin client: it contributes the `q64` language and
launches [`@q64/server`](../server) through `vscode-languageclient`. All
intelligence is in the server and its wasm core — this package is glue.

## Build / package

```sh
pnpm build                 # tsc → dist/extension.js
# bundle the server + wasm under dist/server/ before packaging, then:
npx @vscode/vsce package   # → q64-vscode-x.y.z.vsix
```

## Hosts

Because the server runs in both Node and a Web Worker, this same extension can
target:

- **Desktop VSCode** — server on Node (this entry).
- **vscode.dev / github.dev** — built as a *web extension*, server in a Worker.

## Credentials

None at runtime. The only secret is the marketplace **publish token**, used by
CI to `vsce publish`. It lives as a CI secret and is never committed to this
public repo.
