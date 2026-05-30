# @q64/core-wasm

q64's analysis core, compiled to a single freestanding `q64-core.wasm`, with
TypeScript bindings.

## What it is

`build.zig` compiles q64's **analysis** Zig modules (today: `parser`; later
`typeck`, `effect`, `region`) for `wasm32-freestanding` and exports a tiny C
ABI. It **never links Binaryen** — the analysis path is pure Zig, which is the
whole reason the same source that builds the native `q64` binary can also run
in a browser, a Worker, or Node.

> If this build ever needs Binaryen, an analysis module has wrongly grown a
> codegen dependency. Fix the dependency, not this package.

## ABI

| Export | Signature | Meaning |
|---|---|---|
| `q64_alloc` | `(len) -> ptr` | allocate `len` bytes; host writes source there |
| `q64_diagnose` | `(ptr, len) -> u64` | parse; returns `(out_ptr << 32) \| out_len` of a UTF-8 JSON envelope |
| `q64_free` | `(ptr, len)` | release a buffer (both the input and the returned output) |
| `memory` | — | the module's linear memory |

The JSON envelope matches [`spec/diagnostics.md`](../../../spec/diagnostics.md).

## Bindings

```ts
import { Core } from "@q64/core-wasm";
const core = await Core.load(wasmBytes);   // Node reads a file; browser fetches
const env = core.diagnose("fn main() {}\n");
//   { ok: true, diagnostics: [] }
```

`Core.load` takes raw bytes or a precompiled `WebAssembly.Module`, so the host
decides how the asset arrives. The bindings touch no DOM and no Node APIs.

## Build

```sh
pnpm build          # zig → q64-core.wasm, then tsc → dist/
pnpm run build:wasm # just the wasm
```

Verified: `parser` compiles clean to wasm32 (~62 KB ReleaseSmall) and round-trips
diagnostics from JS.

## Roadmap

As `typeck`/`effect`/`region` land in [`../../../q64`](../../../q64), add
`q64_hover`, `q64_definition`, `q64_effects`, etc. — each a pure
`(source, position?) -> JSON` query. The same query surface is what the LSP
server and the hosted MCP tools both consume.
