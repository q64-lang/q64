# runtime

Host adapters. Each subfolder translates q64's task / scope / channel /
shared-region primitives into the host platform's mechanisms.

User code never imports a runtime adapter directly — the `qube` builder
links the appropriate adapter for the target declared in `qube.json5`.

> **Status: not yet implemented.** Each adapter folder currently holds a
> README describing its responsibility.

## Subfolders

| Folder                                      | Target                                          |
|---------------------------------------------|-------------------------------------------------|
| [`browser/`](./browser)                     | Browsers — JS + SharedArrayBuffer + Web Workers |
| [`wasmtime/`](./wasmtime)                   | Wasmtime (server-side native)                   |
| [`wasmer/`](./wasmer)                       | Wasmer (server-side native)                     |
| [`audio-host/`](./audio-host)               | VST3 / AU / AAX audio plugin hosts              |

## What each adapter does

Per [`design/concurrency.md`](https://github.com/q64-lang/design/blob/main/concurrency.md),
the adapter encapsulates everything the user shouldn't see:

- **Browser**: SharedArrayBuffer, Worker creation, `Atomics.wait/notify`,
  `postMessage`, COOP/COEP header bootstrap, BigInt marshaling for i64
  across the JS boundary, audio-worklet thread affinity.
- **Wasmtime / Wasmer**: OS thread pools, futex-based atomic waits,
  shared linear memory wiring, WASI integration.
- **Audio-host**: real-time-safe scheduling on the host's audio thread,
  lock-free FIFOs for parameter changes, parameter automation marshaling.

What user code *does* see — `scope`, `spawn`, `channel.<T>`, `select`,
`Shared.<T>`, `atomic.<T>`, `actor`, `Signal.<T>`, `Event.<T>`, `Stream.<T>` —
is identical across hosts. The adapter is the boundary.
