# runtime/wasmtime

The Wasmtime runtime adapter. Translates q64's task / scope / channel
primitives into OS threads + shared linear memory + futex-based synchronization.

> **Status: not yet implemented.**

## Responsibilities

- **Thread pool**: OS thread management (pthread / Windows threads).
- **Shared memory**: shared linear-memory wiring via Wasmtime's threading
  proposal.
- **Synchronization**: futex / native condvar bridging for `Atomics.wait`-shaped
  q64 primitives.
- **WASI integration**: capability surface for `env.fs`, `env.net`,
  `env.process`, `env.clock` — wired to WASI Preview 2 components where
  possible.
- **Host calls**: BLAS / cBLAS bindings for `q64.math` large-shape operations.

## Implementation language

Zig. Linked against the Wasmtime C API.
