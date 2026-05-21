# q64/src/codegen

AST → Wasm 3.0 emission. Uses the Binaryen C API.

> **Status: not yet implemented.**

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
- Host glue — `runtime/<host>/` provides the JS / Zig adapter that
  imports into the emitted wasm.

## Inputs / outputs

- **In:** fully-checked AST/TIR from `effect/` (which is the last
  semantic pass).
- **Out:** `.wasm` artifact + sidecar `.effects.json` / `.graph.json`
  for `qube` to consume; diagnostics with `CGN*` and `LNK*` codes.

## External

- **Binaryen** — Wasm 3.0 backend, called via its C API. Vendored in
  `../../vendor/binaryen/`. Alternative MLIR-Wasm dialect path is
  noted in [`design.md`](https://github.com/q64-lang/design/blob/main/design.md)
  §"Compilation Pipeline" but not pursued in v0.
