# q64/src/typeck

Name resolution, type inference, type checking, comptime evaluation.

> **Status: not yet implemented.**

## Scope

**Owns:**
- Name resolution (`NAM*` diagnostics).
- Type inference at let-bindings (Swift/Rust style; no top-level
  inference).
- Type checking and unification.
- Generic instantiation, including const generics for sizes / sample
  rates.
- Comptime evaluation (`CMT*` diagnostics) — evaluating `comptime`
  blocks and parameters during typechecking, since their results feed
  type information.
- Trait / protocol resolution and dispatch selection.

**Does not own:**
- Region tracking → `region/`.
- Effect propagation → `effect/`.
- Stream graph analysis → folded into `effect/` for now.

## Inputs / outputs

- **In:** AST + source map from `parser/`. Module-resolution map from
  the CLI (`--module name=path`); the typechecker is responsible for
  loading and checking imported modules.
- **Out:** typed AST (or TIR — typed intermediate representation,
  TBD), trait-method dispatch table, comptime evaluation results;
  diagnostics with `NAM*`, `TYP*`, `CMT*` codes.

## External

None. Pure Zig.

## Notes

The exact split between AST and TIR (separate IR or annotation-on-AST)
is an implementation detail still to be decided when the first
typechecker patches land. The choice doesn't change this folder's
contract with `region/` and `effect/` — they consume whatever shape
typeck emits.
