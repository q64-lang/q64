# Operator overloading

Status: **draft v0 — decision recorded.** This settles the open question
noted in [`faces.md`](./faces.md) and [`types.md`](./types.md) §"SIMD and
Tensor as language types": *which types may declare fits for operators, and
by what mechanism.*

## The mechanism: operator faces, no new grammar

Operators are overloaded through **compiler-blessed faces in the
auto-prelude** — the ordinary [`faces.md`](./faces.md) machinery, nothing
else. An operator expression on a user type desugars to a fit-method call.
No grammar changes: the operators already parse; overloading is purely a
semantic rule.

| Expression | Desugars to      | Prelude face | Method signature |
|------------|------------------|--------------|------------------|
| `a + b`    | `a.add(b)`       | `Add`        | `fn add(self, rhs: Self) -> Self` |
| `a - b`    | `a.sub(b)`       | `Sub`        | `fn sub(self, rhs: Self) -> Self` |
| `a * b`    | `a.mul(b)`       | `Mul`        | `fn mul(self, rhs: Self) -> Self` |
| `a / b`    | `a.div(b)`       | `Div`        | `fn div(self, rhs: Self) -> Self` |
| `a % b`    | `a.rem(b)`       | `Rem`        | `fn rem(self, rhs: Self) -> Self` |
| `-a`       | `a.neg()`        | `Neg`        | `fn neg(self) -> Self` |

A type opts in with an ordinary fit:

```q64
pub struct Complex { re: f64, im: f64 }

pub fit Complex : Add {
    fn add(self, rhs: Complex) -> Complex {
        Complex { re: self.re + rhs.re, im: self.im + rhs.im }
    }
}

let c = a + b        // ≡ a.add(b)
```

## Rules

- **Homogeneous in v0.** Both operands must be the same type; the result is
  that type (`Self × Self → Self`). There is no implicit conversion in an
  operator expression, exactly as everywhere else (TYP042). Heterogeneous
  operands (scalar × vector, `Mul<Rhs, Out = …>` with an associated output
  type) are the planned extension — deferred until a concrete consumer
  (units arithmetic on user types, `Tensor` broadcasting) pins the design.
- **Primitives keep their compiler lowering.** `i64 + i64` is a wasm
  instruction, never a fit call. The blessed unit/`Simd`/`Tensor` operator
  semantics ([`units.md`](./units.md), [`types.md`](./types.md)) also stay
  compiler-owned; the faces here are the *user-type* mechanism. Whether the
  blessed types are retroactively *expressible* as fits is a later
  unification, not a v0 requirement.
- **Coherence** is [`faces.md`](./faces.md)'s orphan rule, unchanged: fit
  `T : Add` where the face or `T` is local.
- **Effects propagate normally.** An operator method's effect set flows
  into the expression like any call — one propagation rule for everything.
  (An `@io` `add` is legal and visible in the caller's inferred set; style
  guidance is to keep operator fits pure, but the compiler does not
  special-case it.)
- **No laws on the arithmetic operator faces.** Float addition is not
  associative and concatenation-flavored `Add`s are not commutative, so the
  faces would either lie or exclude the two most important fits. A fit MAY
  declare its own laws; the faces themselves are law-free.

## What is deliberately NOT overloadable

- `==` / `!=` — equality is the derived-by-default `Eq` face
  ([`faces.md`](./faces.md)), not an operator fit.
- `<` `<=` `>` `>=` — ordering is `Ord`, same reason.
- `&&` `||` `!` — control flow on `bool`, never dispatched.
- `& | ^ ~ << >>` — bitwise stays integer-only by design.
- Assignment, `[]` indexing (`Index` face is a possible later addition),
  `|>` (a pipe is a call, not an operation on values), and `..`/`..=`.

## Diagnostics

- **TYP360** — operator used on a type with no fit for the corresponding
  face (`a + b` where `a`'s type has no `Add` fit).
- **TYP361** — operand type mismatch in an operator expression (the
  homogeneity rule; the message points at the explicit-conversion idiom).

## v0 implementation status

All of v0 is implemented: `+ - * / %` and unary `-` desugar through the
fit registry (the B4 static-dispatch machinery) on same-struct records —
in `let`-initializer, nested-expression, and argument positions — with
fit methods extended to record parameters and record returns, and fits
resolving on imported types (the registry is per-scope; a fit lives with
its type's module). `q64 check` surfaces **TYP360/361** on provable
shapes (a record of a locally-declared struct under `+ - * / %` or unary
`-`); the emit path keeps rejecting the rest honestly.
