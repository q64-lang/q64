# Automatic differentiation

Status: **design note — not yet normative, nothing implemented.** This
records the intended shape so the numeric ladder (Simd → Tensor) is built
with differentiation in mind, per `docs/language-analysis-2026-07.md` §3.
Without AD, "AI support" means inference only; this is the training story.

## The approach: source-transform reverse mode over HIR

q64 differentiates by **compile-time program transformation**, not by
runtime taping or operator-overloaded dual numbers:

- The two-tier IR is the enabling structure: HIR is desugared, typed, and
  **backend-neutral**, so a `grad` transform is one more HIR→HIR pass —
  it composes with every backend (wasm today, native later) for free.
- Reverse mode first (gradients of scalar losses w.r.t. many parameters —
  the ML shape); forward mode is a later, simpler sibling.

## Surface

```q64
@differentiable
fn loss(w: Tensor<f64, [N]>, x: Tensor<f64, [N]>) -> f64 { … }

let g = grad(loss)          // fn (w, x) -> (Tensor<f64,[N]>, Tensor<f64,[N]>)
let (dw, dx) = g(w0, x0)
```

- **`@differentiable`** marks a function whose HIR the compiler retains for
  transformation. It is checked, not advisory: the body must stay inside
  the differentiable subset or the marker is a compile error (`ADF001`).
- **`grad(f)`** is a comptime operator (not a runtime higher-order
  function): it stamps the adjoint function at compile time, exactly like
  generic monomorphization stamps instances.

## What q64 already has that makes this tractable

1. **Effects delimit the differentiable region.** A `@differentiable`
   function must be `@pure`-compatible: no `@io`, no capabilities, no
   suspension. The effect system already computes this — the AD pass
   simply requires it (`ADF002` on violation). Julia cannot promise this;
   q64 gets it from the existing lattice.
2. **Regions give the tape for free.** Reverse mode records intermediate
   values on the forward pass and consumes them backward. That tape is an
   arena: allocated at `grad`-call entry, freed at exit — the existing
   region machinery, no GC pressure, no new allocator.
3. **No aliasing surprises.** v0 value semantics (no escaping references
   into differentiated code) keep the adjoint rule per-op local.

## The differentiable subset (v0)

Arithmetic on `f64`/`f32`, the float builtins with known adjoints
(`sqrt`, `abs` away from 0, `min`/`max` subgradients), `q64.math`
transcendentals (their adjoints are themselves q64 functions — `exp'` is
`exp`, `ln'` is `1/x`), `Complex` and operator fits (an operator is a fit
call; its adjoint is the transformed method), straight-line code, `if`
(adjoint follows the taken branch), bounded `for`/`while` (tape records
the trip count), calls to other `@differentiable` functions, and — once
they land — `Tensor` ops with registered adjoints. Excluded in v0:
integer-valued paths in the gradient flow, `match` over payloads, Vec
mutation, anything effectful.

## Custom adjoints

A library declares an adjoint the way it declares any fit:

```q64
@adjoint(of: fast_tanh)
fn fast_tanh_adj(x: f64, dy: f64) -> f64 { dy * (1.0 - fast_tanh(x) * fast_tanh(x)) }
```

This is the escape hatch for numerically-better derivatives and for
host-boundary ops (a `env`-backed kernel differentiates only via a
declared adjoint — the compiler cannot see across a capability face,
`ADF003`).

## Diagnostics (reserved)

- **ADF001** — non-differentiable construct inside `@differentiable`.
- **ADF002** — effectful call inside `@differentiable` (points at the
  offending capability).
- **ADF003** — call across a capability face with no `@adjoint`.

## Sequencing

Blocked on: static-shape `Tensor` (the payoff domain) and const generics.
Not blocked on: the typechecker ladder (the transform consumes HIR, which
is already typed enough for the v0 subset). First slice when unblocked:
`grad` of a scalar-only `@differentiable` fn (no tensors) — pure HIR
transform, verified against finite differences in the roundtrip suite.
