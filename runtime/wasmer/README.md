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
  where they go beyond standard WASI. The q64 baseline is WASI Preview 3
  (WASIp3 RC); see [`spec/env.md`](../../spec/env.md) §"Tracking the WASIp3
  release candidate". Preview 2 is not supported; this adapter must track the
  WASIp3 RC to serve the `preview3` default (WASIX covers extensions beyond
  standard WASI; `preview1` remains for legacy core modules).

## Implementation language

Zig. Linked against the Wasmer C API.

## Why both Wasmtime and Wasmer

They cover different deployment niches: Wasmtime for the Bytecode Alliance
mainstream and CDN edges; Wasmer for environments that want WASIX extensions
or Wasmer's specific tooling. The q64 source compiles unchanged for either.
