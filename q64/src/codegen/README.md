# q64/src/codegen

AST → Wasm 3.0 emission. Uses the Binaryen C API.

> **Status: v0 emit-hello path running.** `emit.zig` builds the
> byte-equivalent of `runtime/wasmtime/hello.wat` via Binaryen and
> returns the wasm bytes. End-to-end smoke test in
> `scripts/hello-roundtrip.sh` runs:
> `q64 emit-hello → q64-wasmtime-host → "Hello, q64."`

## Scope

**Owns:**
- AST/TIR → Wasm 3.0 binary emission via Binaryen.
- Wasm 3.0 feature lowering: Memory64, multi-memory, table64,
  WasmGC, threads + atomics, stack-switching, SIMD.
- Region allocator codegen — emits the bump / pool / free-list /
  stack / GC allocator that backs each region kind.
- Cross-heap transfer codegen (explicit copies between linear and
  managed memory).
- Custom wasm sections for graph topology, effect declarations, and
  capability needs (per [`design.md`](https://github.com/q64-lang/design/blob/main/design.md)
  §"Inspection and Introspection").
- Link-step assembly: combine module-local wasm into the final
  artifact, dedupe imports, finalize memory and table sizes.

**Does not own:**
- Type checking, region analysis, effect propagation — already done
  upstream.
- Host glue — `runtime/<host>/` provides the Zig adapter that
  imports into the emitted wasm.

## Inputs / outputs

- **In (today):** none — `emitHelloWasm` is a hand-built fixture.
- **In (eventually):** fully-checked AST/TIR from `effect/` (the
  last semantic pass).
- **Out:** `.wasm` bytes (`emit-hello` writes to a file). Future:
  sidecar `.effects.json` / `.graph.json` for `qube` to consume;
  diagnostics with `CGN*` and `LNK*` codes.

## Files

| File         | Status          | Purpose                                                   |
|--------------|-----------------|-----------------------------------------------------------|
| `emit.zig`   | partial         | Binaryen C-API bindings + `emitHelloWasm` fixture.        |

## External

- **Binaryen** — Wasm 3.0 backend, called via its C API. Vendored
  at `../../vendor/binaryen/` by `init.sh` (pinned version 129 with
  sha256 verification). Static-linked into the `q64` binary.

Binaryen ships only a static archive on Linux, built against
libstdc++ (gcc CI). The build script pulls in `libstdc++.so.6`
and `libgcc_s.so.1` from the system to satisfy the C++ runtime
and unwinder symbols.
