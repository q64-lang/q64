# runtime/wasmtime

The Wasmtime runtime adapter. Translates q64's task / scope / channel
primitives into OS threads + shared linear memory + futex-based
synchronization, and exposes the q64 capability-face imports
(`env.out`, `env.fs.…`, …) to Wasm modules produced by the compiler.

> **Status: v0 host running.** The host embeds wasmtime, loads a
> `.wat` or `.wasm` file, provides `env.out` as a stdout sink, and
> calls `_start`. This is the "back end" of the pipeline — the
> byte-level golden the rest of the toolchain aims at.

## Quickstart

```
./init.sh                              # one-time: vendor zig + wasmtime
cd runtime/wasmtime
../../vendor/zig/zig build hello       # build + run hello.wat, assert stdout
```

Expected output (from `zig build hello`): silent success on stdout
when the assertion passes. Run the binary directly to see the bytes:

```
./zig-out/bin/q64-wasmtime-host hello.wat
# Hello, q64.
```

## v0 ABI

Per [`spec/env.md`](../../spec/env.md) §"Capability faces":

| Import        | Signature                  | Effect                                                                 |
|---------------|----------------------------|------------------------------------------------------------------------|
| `env.out`     | `(ptr: i32, len: i32) → ()` | Writes `len` UTF-8 bytes from linear memory at `ptr` to host stdout.  |

The module must export a single linear memory named `memory` and a
start function named `_start`. The rest of the env surface (`env.fs`,
`env.clock`, …) is unimplemented; modules that import them fail
instantiation with a clear error.

## What lives here

| File                  | Purpose                                                      |
|-----------------------|--------------------------------------------------------------|
| `build.zig`           | Builds the host. `zig build` → binary; `zig build hello` → run + golden assert. |
| `src/main.zig`        | Host: load `.wat`/`.wasm`, define imports, call `_start`.    |
| `hello.wat`           | Hand-crafted hello-world module — the codegen golden.        |

## What's still planned

These are the responsibilities documented for the adapter once the
language and runtime grow into them:

- **Thread pool** — OS thread management for `spawn` / `scope`.
- **Shared memory** — Wasmtime's threading proposal for `Shared<T>`.
- **Synchronization** — futex / native condvar bridging for
  `Atomics.wait`-shaped q64 primitives.
- **WASI integration** — `env.fs`, `env.net`, `env.process`,
  `env.clock` wired to WASI Preview 3 (WASIp3 RC, Wasmtime 43+;
  snapshot `0.3.0-rc-2026-03-15`) components, with Preview 2 as the
  selectable stable fallback. See [`spec/env.md`](../../spec/env.md)
  §"Tracking the WASIp3 release candidate".
- **Host calls** — BLAS / cBLAS bindings for `q64.math` large-shape
  operations.

## Implementation language

Zig. Linked against the Wasmtime C API (`vendor/wasmtime/`).
