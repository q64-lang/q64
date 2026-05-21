# q64/src/effect

Effect inference, propagation, and stream-graph analysis.

> **Status: not yet implemented.**

## Scope

**Owns:**
- Effect inference per function and per stream stage. The fixed core
  set is `@realtime`, `@no_alloc`, `@no_suspend`, `@send`, `@pure`,
  `@io`, `@network` (per [`design.md`](https://github.com/q64-lang/design/blob/main/design.md)
  §Effects).
- Propagation through call graphs — a `@realtime` stage that calls a
  non-realtime function is a compile error.
- Stream graph analysis (`STR*` codes): topology extraction, fusion
  candidate detection, backpressure propagation, `pre`-cycle
  validation, latency bounds where computable.
- Reading per-qube `effects.declared` / `effects.deny` from the
  manifest and reconciling against inferred effects.

**Does not own:**
- `@send` derivation from memory layout → `region/`.
- Capability disclosure surface → `qube audit` + continuum.

## Inputs / outputs

- **In:** region-annotated AST from `region/`. Per-qube manifest
  fragment (the `effects` block from
  [`spec/qube.json5.md`](../../../spec/qube.json5.md)).
- **Out:** effect-annotated AST, stream-graph topology, effect index
  (consumed by `qube` for the registry's capability disclosure);
  diagnostics with `EFF*` and `STR*` codes.

## External

None. Pure Zig.
