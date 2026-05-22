# runtime/browser

The browser runtime adapter. Translates q64's task / scope / channel
primitives into JavaScript + SharedArrayBuffer + Web Workers.

> **Status: v0 — only `env.out` is wired up.** Threading, audio,
> DOM, and the rest below remain to be built.

## v0: `host.js` and `index.html`

`host.js` is a zero-dependency ESM module that exports
`runWasm(url, sink)`. It fetches a `.wasm`, instantiates it with an
`env.out(ptr, len)` import that decodes UTF-8 from the module's linear
memory and forwards it to `sink`, then calls `_start`. This is the
browser-side mirror of `runtime/wasmtime/src/main.zig`'s
`envOutCallback`: same `env.out :: (ptr: i32, len: i32) -> ()` ABI,
same `memory` + `_start` export requirements, same UTF-8 producer
contract. `index.html` is a minimal shell that loads `host.js`, pipes
its sink into a `<pre id="out">`, and references the artifact via the
`{{WASM}}` placeholder that `qube web` rewrites at serve time.

## Responsibilities (full surface, mostly deferred)

- **Thread pool**: Web Worker creation and lifecycle.
- **Shared memory**: SharedArrayBuffer allocation and wiring across Workers.
- **Synchronization**: `Atomics.wait` / `Atomics.notify` / `Atomics.compareExchange`.
- **Message marshaling**: BigInt translation for i64 values crossing the JS
  boundary.
- **Audio**: audio-worklet thread bootstrap and affinity for `@realtime` stages.
- **Headers**: COOP/COEP header guidance baked into a dev server (likely
  exposed via `qube run --target browser`).
- **DOM / Web APIs**: capability surface for `env.dom`, `env.net`, `env.fs`
  (OPFS), `env.gpu` (WebGPU), `env.nn` (WebNN).

## Implementation language

TypeScript (eventually). v0 is plain ESM JS so it can be served as a
static file with no build step.
