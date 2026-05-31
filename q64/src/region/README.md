# q64/src/region

Region tracking, lifetime checking, ownership analysis.

> **Status: not yet implemented.**

## Scope

**Owns:**
- Region inference (which region a value lives in: arena, pool, stack,
  free-list, managed, or shared).
- Lifetime checking — values must not outlive their region; functions
  cannot return locally-allocated values unless the caller supplied
  the region.
- Move / borrow tracking from parameter modes (`in` / `ref` / `out` /
  `move`).
- Cross-region transfer validation (only via named copy operations).
- `@send` derivation from memory composition (per
  [`design/memory.md`](https://github.com/q64-lang/design/blob/main/memory.md)
  §"`@send` is derived from memory composition").

**Does not own:**
- Effect markers other than `@send` → `effect/`.
- Codegen of region allocators → `codegen/`.

## Inputs / outputs

- **In:** typed AST from `typeck/`.
- **Out:** region-annotated AST (per-value region identity, per-binding
  ownership state); diagnostics with `REG*` codes.

## External

None. Pure Zig.

## Notes

Region kinds and the multi-memory layout that backs them are spelled
out in [`design/memory.md`](https://github.com/q64-lang/design/blob/main/memory.md).
This folder enforces the rules at compile time; `codegen/` translates
them into multi-memory wasm.
