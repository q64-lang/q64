# q64/src/codegen

AST → Wasm 3.0 emission. Uses the Binaryen C API.

> **Status: source-driven emission running.** `emit.zig` parses a
> q64 source file, walks `fn main`, and emits a wasm module with
> the program's `env.out("…")` calls laid out in linear memory.
> `q64 emit <file.q> <out.wasm>` then `q64-wasmtime-host out.wasm`
> prints the program's output. `emit.emitHelloWasm` is kept as a
> hand-built fixture for regression testing.

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

- **In (today):** parsed source via `emitFromSource(allocator,
  source, file)` — finds `fn main`, walks its body, emits a wasm
  module. Only `env.out("…")` calls are recognized; everything else
  is `Error.UnsupportedExpression`.
- **In (eventually):** fully-checked AST/TIR from `effect/` (the
  last semantic pass).
- **Out:** `.wasm` bytes. Future: sidecar `.effects.json` /
  `.graph.json` for `qube` to consume; diagnostics with `CGN*` and
  `LNK*` codes.

## Files

| File         | Status          | Purpose                                                   |
|--------------|-----------------|-----------------------------------------------------------|
| `emit.zig`   | partial         | Binaryen bindings, `emitFromSource`, `emitHelloWasm`.     |

## External

- **Binaryen** — Wasm 3.0 backend, called via its C API. Vendored
  at `../../vendor/binaryen/` by `init.sh` (pinned version 129 with
  sha256 verification). Static-linked into the `q64` binary.

Binaryen ships only a static archive on Linux, built against
libstdc++ (gcc CI). The build script pulls in `libstdc++.so.6`
and `libgcc_s.so.1` from the system to satisfy the C++ runtime
and unwinder symbols.
