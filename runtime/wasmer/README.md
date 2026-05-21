# runtime/wasmer

The Wasmer runtime adapter. Translates q64's task / scope / channel
primitives into OS threads + shared linear memory + futex-based synchronization.

> **Status: not yet implemented.**

## Responsibilities

Mirrors [`../wasmtime`](../wasmtime) but against the Wasmer C API:

- **Thread pool**: OS thread management.
- **Shared memory**: shared linear memory via Wasmer's threading support.
- **Synchronization**: native futex / condvar bridging.
- **WASIX integration**: capability surface using Wasmer's WASIX extensions
  where they go beyond WASI Preview 2.

## Implementation language

Zig. Linked against the Wasmer C API.

## Why both Wasmtime and Wasmer

They cover different deployment niches: Wasmtime for the Bytecode Alliance
mainstream and CDN edges; Wasmer for environments that want WASIX extensions
or Wasmer's specific tooling. The q64 source compiles unchanged for either.
