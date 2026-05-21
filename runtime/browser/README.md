# runtime/browser

The browser runtime adapter. Translates q64's task / scope / channel
primitives into JavaScript + SharedArrayBuffer + Web Workers.

> **Status: not yet implemented.**

## Responsibilities

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

TypeScript. Compiled and bundled as the adapter shim that ships next to the
wasm artifact.
