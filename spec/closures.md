# Closures

Lambda literals, capture semantics, function types, and the v0
no-escape rule. This spec owns the constructs the rest of the corpus
already uses informally — `input.map(|x| filter.step(x))` in
[`faces.md`](./faces.md), `assert_panics(|| { … })` in
[`test-framework.md`](./test-framework.md) — and pins exactly what
they mean.

> **Status: draft (v0).** The lambda syntax and `fn` type are settled
> (they have been in [`grammar.md`](./grammar.md) since the grammar
> consolidation). The v0 semantic floor specified here — alias
> capture + the no-escape rule — is deliberately the smallest sound
> design; first-class escaping closures are an explicit v1 item, not
> an oversight.

## Design goals

1. **Zero-cost by construction.** A closure monomorphizes like a
   generic: the higher-order function is specialized per lambda, every
   call is direct, and no allocation ever happens on behalf of a
   closure. There is no hidden environment box.
2. **Sound with regions for free.** v0 closures are **downward-only**:
   a capturing closure cannot leave the frame that created it. Because
   it cannot outlive its frame, it cannot outlive any region, binding,
   or `ref` it captures — the region checker needs no new rules and
   the user needs no lifetime annotations.
3. **One closure kind, not three.** The no-escape rule erases the
   distinction other languages spell `Fn` / `FnMut` / `FnOnce`.
   Whether a capture may be mutated follows the *binding* (`let` vs
   `var`), exactly like ordinary lexical scoping; whether a closure
   may be re-called is never in question because nothing is moved
   into it.
4. **Effects are inferred, carried, and checked.** A closure's effect
   set is inferred from its own body — the same inference that runs
   for named functions per [`effects.md`](./effects.md) — and rides on
   its type. Higher-order functions are effect-polymorphic by default.

## Vocabulary

| Word              | Meaning                                                                  |
|-------------------|--------------------------------------------------------------------------|
| **lambda**        | The literal expression `\|x, y\| expr`.                                  |
| **closure**       | The value a lambda evaluates to: code plus its captures.                 |
| **capture**       | A free variable of the lambda body, resolved in the enclosing scope.     |
| **capture-free**  | A lambda with no captures; a plain function value.                       |
| **`fn` type**     | The function type `fn(T) -> U @spec` (per `grammar.md` §Type expressions). |
| **escape**        | Any flow that could let a closure outlive its defining frame.            |

## Lambda literals

```q64
let double: fn(i64) -> i64 = |x| x * 2

samples.map(|s| s * gain)

assert_panics(|| { decode(bad_input) })
```

- Grammar: `LambdaExpr := "|" LambdaParams? "|" Expr` (per
  [`grammar.md`](./grammar.md) §Expressions). The body is one
  expression; since a `Block` is an expression, multi-statement
  bodies are spelled `|x| { … }`.
- Parameters are **untyped in the source**. Their types come from the
  expected `fn` type at the use site — an argument position whose
  parameter is `fn`-typed, or a `let` with an explicit `fn` type
  annotation. A lambda in a position with no expected function type
  is `TYP350`; there is no standalone inference of lambda parameter
  types in v0 (consistent with [`types.md`](./types.md): inference is
  at bindings, never invented from a body alone).
- Arity must match the expected type exactly (`TYP351`).
- The lambda's return type is checked against the expected type's
  return; the body is type-checked with the parameter types
  substituted (ordinary bidirectional checking).

## Capture semantics — aliases, not copies

A lambda body may reference any binding visible at the lambda
expression. Every capture is an **alias** of the enclosing binding —
no copy, no move, no implicit `Clone`:

- A `let` binding (and an `in`-mode parameter) is captured as an
  **immutable alias**. Assigning to it inside the body is `TYP352`.
- A `var` binding (and a `ref`-mode parameter) is captured as a
  **mutable alias**. Reads and assignments inside the body hit the
  enclosing binding directly.

```q64
fn process(input: Signal<f32, 48.kHz>, ref filter: Lowpass) {
    var clipped = 0
    let limit   = 0.95

    input.map(|s| {
        if s > limit { clipped = clipped + 1 }   // ✓ var: mutable alias
        filter.step(s)                            // ✓ ref param: mutable alias
    })
}
```

This is ordinary lexical scoping: the rules for what a lambda body
may do with a name are the rules the enclosing function already has
for that name. Nothing is snapshotted, so there is no "captured stale
copy" surprise; nothing is moved, so a closure can always be called
again.

Alias capture is only sound because of the rule that pays for
everything else:

## The no-escape rule (v0)

A closure that captures **must not escape the frame that created
it**. It may be:

- bound with `let` and called locally,
- passed **down** as an argument (through any depth of calls),
- called any number of times.

It may **not** (`TYP353`):

- be returned from the function that created it,
- be stored in a struct, enum, array, `Vec`, or any field,
- be assigned to a `static`, `state`, or `@state` binding,
- be sent on a channel (it is never `@send`; see
  [`effects.md`](./effects.md) §"`@send`"),
- be captured by `spawn` or by an `actor` (per
  [`concurrency.md`](./concurrency.md), a task may outlive the
  spawning frame),
- be captured by another closure that itself escapes,
- appear in a `pub` component-surface signature (closures never cross
  the canonical ABI; per [`modules.md`](./modules.md) §"Lowering q64
  types to the canonical ABI" and [`rpc.md`](./rpc.md) `RPC010`).

The check is a frame-local flow analysis: a closure value's
permitted sinks are calls and argument positions; every other sink
is `TYP353`, reported at the escaping expression with a note
pointing at the lambda.

**Capture-free lambdas are exempt.** A lambda that captures nothing
is a plain function value: it may be returned, stored, and kept
anywhere a `fn`-typed value is legal. (It still cannot cross the
component ABI in v0 — function values have no canonical-ABI
lowering.)

```q64
fn pick(neg: bool) -> fn(i64) -> i64 {
    if neg { |x| -x } else { |x| x }      // ✓ capture-free; first-class
}

fn counter() -> fn() -> i64 {
    var n = 0
    || { n = n + 1; n }                   // ❌ TYP353 — captures `n`, escapes via return
}
```

## Higher-order functions and the `fn` type

The type of a function parameter that accepts a closure is the `fn`
type from [`grammar.md`](./grammar.md) §Type expressions:

```
FnType := "fn" "(" FnTypeParams? ")" ("->" TypeExpr)? EffectSpec?
```

A `fn`-typed **parameter** is implicitly generic, by the same
machinery as implicit face parameters
([`generics.md`](./generics.md) §"Implicit face parameters"): each
such parameter desugars to a fresh anonymous type parameter bounded
by the function contract, monomorphized per call site. Two `fn`-typed
parameters get two independent fresh parameters.

```q64
fn map<T, U>(xs: [T], f: fn(T) -> U) -> Vec<U> { … }

// desugars (conceptually) to
fn map<T, U, F: fn(T) -> U>(xs: [T], f: F) -> Vec<U> { … }
```

Consequences:

- The closure's concrete code is statically known inside the
  specialized `map`; the call `f(x)` compiles to a direct call.
- Passing a named function where a `fn` type is expected is legal;
  a named `pub fn` is capture-free by construction.
- The monomorphization-growth warning threshold from
  [`generics.md`](./generics.md) applies unchanged.

`fn`-typed values follow the no-escape rule through binding flow: a
`let`-bound closure passed to `map` is fine; the same binding
returned from the function is `TYP353`.

## Effects

A closure's effect set is **inferred from its own body**, exactly as
for a named function (the inference and implication closure of
[`effects.md`](./effects.md)). It is *not* inherited from the
enclosing function — a pure lambda inside an `@io` function is
`@pure`.

The `fn` type's `EffectSpec` slot is where effects are checked:

- **Bare `fn(T) -> U` parameter** — implicitly effect-polymorphic.
  The parameter gets a fresh effect variable (the effect analogue of
  the fresh anonymous type parameter), and that variable joins the
  enclosing function's inferred set wherever the closure is called.
  A higher-order function therefore propagates its argument's
  effects without ceremony, and `q64 show effects` displays the
  variable on the specialized instantiations.
- **Explicit `EffectSpec`** — an upper bound. `f: fn(f32) -> f32
  @pure` accepts only closures whose inferred set is within `@pure`;
  `@realtime` admits only realtime-safe bodies. A closure whose
  inferred set exceeds the spec is `EFF170`, reported at the argument
  with the offending markers named.
- **Shared effect variables** — declare the variable to relate
  positions, per [`generics.md`](./generics.md) §effect parameters:

```q64
fn retry<@e>(op: fn() -> Result<(), Error> @e, attempts: i64) -> Result<(), Error> @e {
    …
}
```

Asserts compose as expected: inside an `@realtime` function, calling
a closure parameter requires that parameter's spec (or inferred
instantiation) to be realtime-admissible — the standard callee rule
from [`effects.md`](./effects.md), with the closure as callee.

Explicit effect annotation **on the lambda literal** stays deferred
(per [`effects.md`](./effects.md) §"Open items deferred" and
[`grammar.md`](./grammar.md) §"Open items deferred"); the inferred
set plus the `fn` type's spec covers v0.

## Memory and lowering

No part of a closure is heap-allocated:

- Captures lower as extra arguments to the lambda's generated
  function: immutable scalar captures pass by value; mutable captures
  (and non-scalar immutable ones) pass as pointers into the enclosing
  frame. A wasm local that is mutably captured spills to the `Stack`
  region ([`memory.md`](./memory.md) §"Region kinds") so it is
  addressable; this is the only observable cost of capturing a `var`.
- Because the higher-order function is monomorphized, the capture
  list is statically known and the "environment" is just those
  arguments — there is no environment struct unless the backend
  chooses one as an internal calling convention.
- A capture-free lambda used as a first-class value lowers to a
  `funcref` table entry and calls through `call_indirect`; used in
  argument position it monomorphizes like any other lambda and stays
  a direct call.
- Closures and `fn`-typed values have **no canonical-ABI lowering**
  and never appear in a synthesized WIT world (per
  [`modules.md`](./modules.md)).

`@no_alloc` and `@realtime` bodies may therefore create and call
closures freely — creating a closure allocates nothing. The body of
the closure is checked against those asserts like any other code.

## Interactions pinned elsewhere

- **Optional narrowing does not cross a lambda boundary** — a `T?`
  narrowed in the enclosing function is `T?` again inside the body
  (per [`types.md`](./types.md) §"What is **not** narrowed in v0").
- **`@test` cannot be a lambda** (`TST003`, per
  [`test-framework.md`](./test-framework.md)).
- **Stages are named functions.** `@stage` does not apply to a lambda
  in v0; graph nodes are declared per [`streams.md`](./streams.md).

## Diagnostic codes

| Code     | Short message                                  | When                                                                                  |
|----------|------------------------------------------------|----------------------------------------------------------------------------------------|
| `TYP350` | lambda needs an expected function type         | A lambda appears in a position with no expected `fn` type (e.g. an unannotated `let`). |
| `TYP351` | lambda arity mismatch                          | Lambda parameter count differs from the expected `fn` type.                             |
| `TYP352` | assignment to immutably-captured binding       | The body assigns to a captured `let` binding or `in`-mode parameter.                    |
| `TYP353` | closure escapes its defining frame             | A capturing closure is returned, stored, sent, spawned, or captured by an escaping closure. |
| `EFF170` | closure effects exceed the expected spec       | The closure's inferred effect set is not within the `fn` type's `EffectSpec`.           |

## Open items deferred

- **Escaping (first-class) closures.** A heap- or managed-backed
  closure that may be stored and returned — the `dyn`-dispatch
  analogue for function values. Blocked on the destructor story
  ([`memory.md`](./memory.md) §"Open items deferred") and wanted by
  Stage 3 reactivity ([`reactivity.md`](./reactivity.md)); the
  design space (region-tagged `Closure<R>` vs managed-only) is open.
- **`move` / by-value captures.** All v0 captures are aliases; an
  explicit `move |x| …` snapshot form lands together with escaping
  closures, where it becomes necessary.
- **Typed lambda parameters** (`|x: i64| …`) as a local override of
  the expected type.
- **Effect annotation on the lambda literal** — per
  [`effects.md`](./effects.md) §"Open items deferred".
- **Closures as stages** — `@stage`-shaped anonymous nodes in a
  `graph` body, per [`streams.md`](./streams.md) §"Open items
  deferred".

## Related specs

- [`grammar.md`](./grammar.md) — `LambdaExpr`, `FnType` productions.
- [`generics.md`](./generics.md) — implicit parameters,
  monomorphization, effect variables.
- [`effects.md`](./effects.md) — inference, implication closure,
  asserts.
- [`memory.md`](./memory.md) — regions, the `Stack` region, spilling.
- [`types.md`](./types.md) — bidirectional checking, narrowing
  boundaries.
- [`modules.md`](./modules.md) / [`rpc.md`](./rpc.md) — closures
  excluded from the component ABI and RPC surfaces.
