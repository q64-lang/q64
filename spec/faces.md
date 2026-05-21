# Faces and Fits

How q64 expresses type-class-style polymorphism: declaring shared
interfaces with `face`, binding types to faces with `fit`, and the
q64-native extensions (effect-polymorphism, region-parameterization,
auto-derive, and laws).

> **Status: draft (v0).** Names settled (`face`, `fit`); core shape
> settled (hybrid: single-parameter faces use `fit Type : Face`,
> multi-parameter faces use `fit Face<T1, T2>`). Some surface details
> (`where`-clause grammar, full dyn-safety rules, the auto-derive
> table) will firm up with implementation.

## Canonical example — `face`, `fit`, `fn` together

These three keywords are the polymorphism trio in q64 and almost always
appear in the same neighborhood: a `face` declares the contract, a `fit`
binds a type to the contract, and a `fn` (generic, bound by the face)
uses the contract through that binding. Read this once; the rest of the
spec is detail.

```q64
//! gfx-demo — colors and a tiny printer.

import q64.io

// 1. face — declare the contract.
pub face Display {
    fn fmt(self) -> str @pure
}

pub struct Color { r: u8, g: u8, b: u8 }

// 2. fit — bind a type to the face.
pub fit Color : Display {
    fn fmt(self) -> str {
        "#{self.r:02x}{self.g:02x}{self.b:02x}"
    }
}

// 3. fn — use the face as a bound on a generic.
pub fn print_all<T: Display>(env: Env, items: [T]) {
    for item in items {
        env.out("{item.fmt()}")
    }
}

fn main(env: Env) {
    print_all(env, [
        Color { r: 255, g: 0,   b: 0   },
        Color { r: 0,   g: 255, b: 0   },
        Color { r: 0,   g: 0,   b: 255 },
    ])
}
```

What's happening:

- **`face Display`** declares that any type fitting it provides a `fmt`
  method returning a `str` with no side effects (`@pure`).
- **`fit Color : Display`** is the binding. The compiler verifies
  that the body matches the face's signature exactly, including the
  `@pure` effect.
- **`fn print_all<T: Display>`** is generic over any `T` that fits
  `Display`. At each call site, the compiler monomorphizes `print_all`
  for the concrete `T` — here, `T = Color`. Zero runtime overhead, full
  inlining, predictable `@realtime` behavior.

Every q64 program uses this triangle of `fn` + `face` + `fit`
constantly. Reading or writing q64 source is largely scanning for these
three keywords and following the arrows between them.

## Design goals

1. **Static dispatch by default.** Generic functions over faces
   monomorphize at compile time — zero runtime overhead, predictable
   `@realtime` reasoning, full inlining across face boundaries.
2. **Multi-parameter dispatch as a first-class shape.** Conversion
   lattices (`PCM<i16> → PCM<f32>`, `sRGB → Linear`,
   `WhisperVocab → LlamaVocab`) deserve direct expression — no awkward
   "pick one type to be the receiver."
3. **Effects, regions, and comptime threaded through.** Face systems
   in other languages bolt these on; q64 builds them in from v0 so
   stdlib can use them without retrofit.
4. **AI-agent friendly.** Faces and fits are nominal and greppable —
   `grep '^pub fit Eq'` enumerates every type that fits `Eq`.

## Vocabulary

| Word     | Meaning                                                                     |
|----------|-----------------------------------------------------------------------------|
| `face`   | A named interface — methods, associated types, default impls, and laws.      |
| `fit`    | A binding that says "this type (or these types) fit this face."             |
| **bound**| A constraint on a generic parameter — `T: Eq<T>` reads "`T` must fit `Eq`." |
| **dyn**  | A type position that erases the concrete type and dispatches at runtime.    |

Compiler error messages use the same vocabulary: *"Vec3 does not fit Eq"*,
*"face Convert<From, To> is not satisfied for (PCM<i16>, PCM<f24>)"*.

## Face declaration

```q64
pub face Eq<T> {
    fn eq(a: T, b: T) -> bool @pure
    fn ne(a: T, b: T) -> bool @pure { !Eq.eq(a, b) }      // default method

    law reflexive:  forall a: T          => eq(a, a)
    law symmetric:  forall a, b: T       => eq(a, b) == eq(b, a)
    law transitive: forall a, b, c: T    => (eq(a, b) && eq(b, c)) => eq(a, c)
}
```

A face declaration contains:

- **Generic parameters** — `<T>`, `<From, To>`, `<T, R: Region, @e>`, etc.
  The `< >` sigil distinguishes generic parameter lists from array
  literals and subscript expressions, which use bare `[ ]`.
- **Method signatures** — each with optional effect markers.
- **Associated types** — `type Item` declarations whose concrete type each
  fit supplies.
- **Default methods** — full bodies that fits may override.
- **Laws** (optional) — `law name: forall …` algebraic statements that
  `qube test` auto-checks via property tests.

### Method signatures

Method effects belong **after** the return type, reusing the function-
effect grammar from
[`effects.md`](./effects.md):

```q64
pub face Process<In, Out> {
    fn step(self, x: In) -> Out @realtime
}
```

A fit's method must satisfy the declared effect set — a `@realtime` face
method cannot be fit with a non-`@realtime` body.

### Associated types

For relationships that don't fit a regular type parameter, use
associated types:

```q64
pub face Iterator {
    type Item
    fn next(self: ref Self) -> Self.Item?
}
```

Inside the face body, `Self.Item` refers to the associated type. A fit
supplies the concrete type:

```q64
pub fit VecIter<T> : Iterator {
    type Item = T
    fn next(self: ref Self) -> T? { ... }
}
```

### Default methods

A face method with a body is a default. Fits may override it; if they
don't, the default is used. Defaults may call other methods on the
face (including other defaults).

### Self

Inside a single-parameter face's body, `Self` refers to the type the
face is being declared for. Multi-parameter faces have no `Self` — every
type is a named parameter.

```q64
pub face Clone {
    fn clone(self) -> Self
}

pub face Convert<From, To> {            // no Self; both types named
    fn convert(x: From) -> To
}
```

### Face inheritance

A face may require another face as a superface:

```q64
pub face Hash<T>: Eq<T> {
    fn hash(self) -> u64 @pure
}
```

Any `fit Hash<X>` requires that `Eq<X>` is also fit.

## Fit declaration

`fit` binds a face to one or more types. The form depends on whether
the face has a single conceptual receiver or several independent type
parameters:

- **Single-parameter faces** use `fit Type : Face` — implementer first,
  face after `:`. Reads as "this type fits this face."
- **Multi-parameter faces** use `fit Face<T1, T2>` — types are positional
  in the face's parameter list; no single implementer.

The rule is mechanical, not stylistic, and the compiler enforces it
based on the face declaration.

### Single-parameter faces — `fit Type : Face`

```q64
pub fit Vec3<f32> : Eq {
    fn eq(a: Vec3<f32>, b: Vec3<f32>) -> bool {
        a.x == b.x && a.y == b.y && a.z == b.z
    }
}

pub fit Vec3<f32> : Display {
    fn fmt(self) -> str { "Vec3({self.x}, {self.y}, {self.z})" }
}
```

When the face also has effect or region parameters (Self plus aux
params), the aux params go on the face after `:`:

```q64
pub fit LowPass : Filter<PCM<f32>, @realtime> {
    fn step(self: ref Self, x: PCM<f32>) -> PCM<f32> @realtime { ... }
}

pub fit Vec<i64, Arena> : Collection<i64, Arena> {
    fn push(self: ref Self, r: Arena, x: i64) { ... }
}
```

### Multi-parameter faces — `fit Face<T1, T2>`

```q64
pub fit Convert<PCM<i16>, PCM<f32>> {
    fn convert(x: PCM<i16>) -> PCM<f32> {
        PCM<f32>(f32(x.0) / 32768.0)
    }
}

pub fit Convert<Rgb<sRGB, u8>, Rgb<Linear, f32>> {
    fn convert(x: Rgb<sRGB, u8>) -> Rgb<Linear, f32> { ... }
}
```

### Visibility

A `pub fit` is reachable by consumers of the qube; a fit without `pub`
is private to the file. Per
[`modules.md`](./modules.md) §Re-exports, only fits reachable
through `pub use` chains from the qube entry point cross the qube
boundary.

## Bounds and constraints

### Inline bounds on generic parameters

```q64
pub fn unique<T: Eq<T>>(items: [T]) -> [T] { ... }

pub fn dedup_sorted<T: Eq<T> + Ord<T>>(items: ref [T]) { ... }
```

`+` composes bounds. Reads naturally: *"T must fit Eq and Ord."*

### `where` clause for complex bounds

When a bound is verbose or involves associated types, the `where`
clause keeps the parameter list readable:

```q64
pub fn collect<I, C>(it: I) -> C
where
    I: Iterator,
    C: Collection<I.Item, _>,
{ ... }
```

The `where` clause is the only place to express bounds on associated
types and bounds with effect or region parameters that would clutter
the inline form. Placement, grammar, and the full set of allowed
forms are specified in [`generics.md`](./generics.md) §"The `where`
clause."

### Bounds on multi-parameter faces

```q64
pub fn pipeline<A, B, C>(x: A) -> C
where
    Convert<A, B>,
    Convert<B, C>,
{
    let mid = Convert.convert(x)
    Convert.convert(mid)
}
```

Calls disambiguate via the face name (`Convert.convert`); the compiler
infers `From` and `To` from the surrounding context.

## Effect-polymorphic faces (q64-native enhancement)

A face may carry an effect variable that each fit binds. Bounds can
then constrain on the effect, not just face membership.

```q64
pub face Filter<T, @e> {
    fn step(self: ref Self, x: T) -> T @e

    law preserves_silence: forall self => step(self, T.silence()) == T.silence()
}

pub fit LowPass : Filter<PCM<f32>, @realtime> {
    fn step(self: ref Self, x: PCM<f32>) -> PCM<f32> @realtime { ... }
}

pub fit FileSink : Filter<Bytes, @io> {
    fn step(self: ref Self, x: Bytes) -> Bytes @io { ... }
}

// Caller constrains the effect: only @realtime fits accepted
pub fn run_audio<F: Filter<PCM<f32>, @realtime>>(
    filter: ref F,
    input: Stream<PCM<f32>>,
) -> Stream<PCM<f32>> {
    input.map(|x| filter.step(x))
}
```

**Effect variables** (`@e`) are written with the same `@` sigil as
concrete effect markers. They unify per-fit: a fit binds `@e` to a
concrete effect (`@realtime`, `@io`, etc.), and the face's method
contract is rewritten with that binding.

**Effect bounds compose:**

```q64
pub fn audio_no_alloc<F: Filter<PCM<f32>, @realtime + @no_alloc>>(
    filter: ref F,
) { ... }
```

This is the primary mechanism by which the audio-thread pipeline gates
out non-realtime work at the type level.

## Region-parameterized faces (q64-native enhancement)

Same shape, with a region variable:

```q64
pub face Collection<T, R: Region> {
    fn push(self: ref Self, r: R, x: T)
    fn pop(self: ref Self) -> T?
    fn len(self) -> usize
}

pub fit Vec<i64, Arena> : Collection<i64, Arena> { ... }
pub fit Vec<i64, Managed> : Collection<i64, Managed> { ... }
```

Callers stay generic over the region:

```q64
pub fn collect<T, R: Region, C: Collection<T, R>>
    (r: R, items: Stream<T>) -> C { ... }
```

Region parameters interact with the lifetime checker from
[`memory.md`](./memory.md)
exactly as they do on plain function signatures — no separate face
machinery is needed.

## Auto-derive (q64-native enhancement)

q64 inverts the usual convention. Structural faces are **derived by
default** when their requirements are satisfiable; you opt out only when
you need to suppress automatic derivation or supply a hand-written fit.

```q64
pub struct Vec3<T> { x: T, y: T, z: T }

// Eq, Hash, Display, Clone are automatic when T fits the same face.
// The compiler synthesizes the obvious field-by-field implementation.
```

### Faces auto-derived when applicable

| Face       | Auto-derived when…                                              |
|------------|------------------------------------------------------------------|
| `Eq`       | Every field's type fits `Eq`                                     |
| `Hash`     | Every field's type fits `Hash` (implies `Eq` per inheritance)    |
| `Clone`    | Every field's type fits `Clone`                                  |
| `Display`  | Every field's type fits `Display`                                |
| `Debug`    | Always derivable (compiler-built reflection)                     |
| `Ord`      | Every field's type fits `Ord`                                    |

User-defined faces are **not** auto-derived. The mechanism is fixed at
the language level for these blessed faces and may grow over time, but
cannot be extended by user code.

### Opting out

```q64
@no_derive(Hash)
pub struct Tagged { id: i64, data: ref [u8] }
```

Disabling auto-derive for a face requires the user to either provide a
hand-written fit or accept that the type does not fit that face. The
`@no_derive` attribute also suppresses the otherwise-implied `Eq` (or
other superfaces in the inheritance chain) only if explicitly listed.

### Suppressing all auto-derive on a type

```q64
@no_derive(*)
pub struct Opaque { ... }
```

`@no_derive(*)` is the all-deny form. Useful for types with hidden
invariants where the obvious field-by-field impl would be wrong.

## Laws (q64-native enhancement)

`law` declarations inside a face are algebraic statements over its
methods. `qube test` reads them and auto-generates property tests for
every fit, using the law statements as predicates.

```q64
pub face Monoid<T> {
    fn zero() -> T
    fn combine(a: T, b: T) -> T

    law left_id:     forall a: T          => combine(zero(), a) == a
    law right_id:    forall a: T          => combine(a, zero()) == a
    law associative: forall a, b, c: T    => combine(combine(a, b), c) == combine(a, combine(b, c))
}
```

For each `fit X : Monoid`, `qube test` runs the three laws against
randomly generated `X` values. Counter-examples surface as standard
diagnostic envelopes with `severity: "error"` and `code: "TYP218"`
(see "Diagnostic codes" below), shrunken to a minimal failing case.

### Generating random values

Property testing needs an `Arbitrary` face — itself auto-derived for
structural types whose fields fit `Arbitrary`. Primitive types fit
`Arbitrary` from the language; user code only writes one when the
auto-derived generator wouldn't produce useful test inputs.

### Opting out of property testing

```q64
@skip_laws
pub fit FloatingPointSum : Monoid {
    // Floating-point addition is not associative — declare the fit
    // but skip property tests that would fail.
}
```

`@skip_laws` is honest about not satisfying the laws; the fit still
works, but `qube test` won't claim it does.

## Static vs dynamic dispatch

### Default: static dispatch via monomorphization

```q64
pub fn unique<T: Eq<T>>(items: [T]) -> [T] { ... }
```

The compiler emits one monomorphized copy of `unique` per concrete `T`.
Zero runtime overhead; full inlining; predictable `@realtime` reasoning.

### Opt-in: dynamic dispatch via `dyn`

```q64
pub fn render(target: dyn Display) {
    target.fmt()        // virtual call through a vtable
}
```

`dyn Face` is a type position. It is **separate** from the face-as-a-bound:
`fn f<T: Display>` is static, `fn f(x: dyn Display)` is dynamic. Per
[`docs/history/influences.md`](../docs/history/influences.md)
§Swift, q64 deliberately separates "face as interface" from "face as
existential type" — Swift's conflation causes the `Self`-with-existential
pain that q64 avoids.

### Dyn-safety

A face can be used as `dyn Face` only if it is **dyn-safe**:

- All methods take `self` (no associated functions / no static-only
  members).
- No method returns `Self` (would require unboxing).
- No method has type parameters of its own (would block vtable layout).
- Associated types must be specified at the use site
  (`dyn Iterator<Item = i64>`).

The compiler reports a non-dyn-safe face used in `dyn` position as
`TYP207`.

### Cost we accept

Monomorphization grows wasm binary size. Mitigations available:
- `qube build` warns when a single generic exceeds N instantiations.
- A `@code_size` annotation routes specific functions to dynamic
  dispatch when binary size matters more than speed.
- The compiler may dedupe identical post-monomorphization bodies (see
  Rust's polyhedral lowering for prior art).

None of these change the default; they are escape hatches.

## Coherence

q64 relaxes Rust's strict orphan rule. A `fit Face<T1, T2, ...>` is
allowed when **at least one of the face or any type parameter is
declared in the current qube.** This permits the common patterns the
orphan rule blocks — implementing `Display` for a stdlib type your code
uses, or implementing a stdlib face for a stdlib type when both are
needed and neither qube has reason to declare the fit themselves.

### Conflict resolution

If two qubes both declare conflicting fits and a third qube depends on
both, the resolver reports `TYP204` with both source locations and asks
the user to resolve by either yanking one fit or wrapping a type in a
newtype.

Conflicts are diagnosed at build time, not runtime — there is no late
binding that could surprise.

## Static `Face.method` and `Face.Type` paths

Methods and associated types are addressable through the face name
when type inference can't resolve them from context:

```q64
let cf        = Convert<PCM<i16>, PCM<f32>>.convert(sample)
let item_type = Iterator<MyIter>.Item
```

The `< >` sigil supplies the face's type parameters explicitly. In
most code, inference resolves them and the shorter `obj.method(...)`
or `Face.method(...)` forms suffice; the explicit form is the escape
hatch for the call sites where inference can't.

## Diagnostic codes

All face/fit-related diagnostics use the `TYP` prefix (face/fit
checking is a typecheck concern). Stable numbering, never reused.

| Code     | Short message                                | When                                                                              |
|----------|----------------------------------------------|-----------------------------------------------------------------------------------|
| `TYP200` | type does not fit face                       | Generic instantiation requires a face that the supplied type does not fit.        |
| `TYP201` | wrong fit form for single-param face         | Single-parameter face must use `fit Type : Face` (implementer first).             |
| `TYP202` | wrong fit form for multi-param face          | Multi-parameter face must use `fit Face<T1, T2>` (no `:`, no implementer prefix). |
| `TYP203` | overlapping fits                             | Two fits both match the same type combination.                                    |
| `TYP204` | coherence violation                          | Fit's face and all parameter types are external to this qube.                     |
| `TYP205` | face arity mismatch                          | Fit supplies a different number of type parameters than the face declares.        |
| `TYP206` | missing associated type                      | Fit does not supply a `type X = …` declaration the face requires.                 |
| `TYP207` | face is not dyn-safe                         | `dyn Face` used on a face whose methods preclude dynamic dispatch.                |
| `TYP208` | face inheritance cycle                       | `face A: B`, `face B: A` form a cycle.                                            |
| `TYP209` | effect bound mismatch                        | Bound requires effect `@e`, fit provides a different (or weaker) effect.          |
| `TYP210` | unsatisfied face bound                       | Generic call cannot prove the bound `T: Face<T>`.                                 |
| `TYP211` | wrong method signature in fit                | Fit's method does not match the face's declared signature (or effect set).        |
| `TYP212` | default method recursion                     | A face default calls another default that ultimately calls back, with no override.|
| `TYP213` | auto-derive failed                           | Auto-derive required a field type to fit a face; it doesn't.                      |
| `TYP214` | redundant `@no_derive`                       | `@no_derive(X)` named a face that wouldn't have been derived anyway.              |
| `TYP215` | unknown face                                 | Bound or fit references a face name not in scope.                                 |
| `TYP216` | unknown method on face                       | Fit defines a method not declared in the face.                                    |
| `TYP217` | missing method in fit                        | Fit omits a face method that has no default.                                      |
| `TYP218` | property test law violated                   | `qube test` found a counter-example for a face law. Shrunk input attached.        |
| `TYP219` | `@skip_laws` on a fit with no laws           | `@skip_laws` attribute applied to a face that has no laws to skip.                |

All codes are emitted using the standard envelope from
[`diagnostics.md`](./diagnostics.md).

## Auto-prelude faces

The language's auto-prelude (per
[`modules.md`](./modules.md) §Forbidden) includes a small set of faces
that every q64 file can name without an explicit import:

| Face         | Provides                                         |
|--------------|--------------------------------------------------|
| `Eq`         | equality                                         |
| `Ord`        | total ordering                                   |
| `Hash`       | hashing                                          |
| `Clone`      | deep copy                                        |
| `Display`    | human-readable string                            |
| `Debug`      | machine-readable string for diagnostics          |
| `Iterator`   | sequential access; powers `for` loops            |
| `Default`    | a "zero" value                                   |
| `From, Into` | infallible cross-type conversion (single-param)  |
| `TryFrom, TryInto` | fallible conversion                       |
| `Arbitrary`  | random value generator (used by property tests)  |

`Convert` is **not** auto-prelude because its multi-parameter form is
typically explicit at call sites; agents should see the import. The
prelude is curated; user code cannot add to it.

## Grammar (informal)

```
FaceDecl    := Visibility? "face" Ident GenericParams? FaceSuperList? "{" FaceItem* "}"
FaceSuperList := ":" FaceRef ("+" FaceRef)*
FaceItem    := TypeAlias | MethodSig | LawDecl
TypeAlias   := "type" Ident ("=" TypeExpr)?
MethodSig   := "fn" Ident "(" Params? ")" ("->" TypeExpr)? EffectSpec? MethodBody?
MethodBody  := "{" Stmt* "}"
LawDecl     := "law" Ident ":" "forall" QuantList "=>" PredicateExpr

FitDecl     := Visibility? "fit" FitSpec "{" FitItem* "}"
FitSpec     := TypeExpr ":" FaceRef        // single-param face: Implementer : Face<AuxArgs?>
             | FaceRef                      // multi-param face: Face<T1, T2>
FitItem     := TypeAlias | MethodDecl
MethodDecl  := "fn" Ident "(" Params? ")" ("->" TypeExpr)? EffectSpec? MethodBody

FaceRef     := Ident GenericArgs?     // e.g. `Eq`, `Filter<PCM<f32>, @realtime>`, `Convert<Rgb, Hex>`
Bound       := Ident ":" FaceRef ("+" FaceRef)*

DynType     := "dyn" FaceRef
```

The `GenericParams`, `GenericArgs`, and `WhereClause` non-terminals
are defined in [`generics.md`](./generics.md) §Grammar. Faces use
them unchanged: a face declares parameters of all four kinds (type,
const, region, effect), bounds compose with `+`, and the `where`
clause sits after the signature and before the body.

Note: `GenericParams` (declaration) and `GenericArgs` (application) use
the same `< >` sigil. Bare `[ ]` is reserved for array literals and
subscripting; `< >` is reserved for generic parameter and argument
lists. The sigil makes the type-level vs value-level distinction
unambiguous at every use site.

The block-form `face { fit { … } }` is not supported — every `face` and
every `fit` is a top-level item (per
[`modules.md`](./modules.md) §"Block `pub` is forbidden").

## Examples

### Equality with laws

```q64
pub face Eq<T> {
    fn eq(a: T, b: T) -> bool @pure
    fn ne(a: T, b: T) -> bool @pure { !Eq.eq(a, b) }

    law reflexive:  forall a: T          => eq(a, a)
    law symmetric:  forall a, b: T       => eq(a, b) == eq(b, a)
    law transitive: forall a, b, c: T    => (eq(a, b) && eq(b, c)) => eq(a, c)
}

// Auto-derived; no explicit fit needed
pub struct Vec3<T> { x: T, y: T, z: T }
```

### Conversion (multi-parameter, brackets-only)

```q64
pub face Convert<From, To> {
    fn convert(x: From) -> To
}

pub fit Convert<PCM<i16>, PCM<f32>> {
    fn convert(x: PCM<i16>) -> PCM<f32> {
        PCM<f32>(f32(x.0) / 32768.0)
    }
}

pub fit Convert<Rgb<sRGB, u8>, Rgb<Linear, f32>> {
    fn convert(x: Rgb<sRGB, u8>) -> Rgb<Linear, f32> { ... }
}
```

### Effect-polymorphic processing

```q64
pub face Filter<T, @e> {
    fn step(self: ref Self, x: T) -> T @e
}

pub fit LowPass : Filter<PCM<f32>, @realtime> {
    fn step(self: ref Self, x: PCM<f32>) -> PCM<f32> @realtime { ... }
}

pub fn run_audio_chain<F: Filter<PCM<f32>, @realtime>>(
    filter: ref F,
    input: Stream<PCM<f32>>,
) -> Stream<PCM<f32>> {
    input.map(|x| filter.step(x))
}
```

### Iterator with associated type

```q64
pub face Iterator {
    type Item
    fn next(self: ref Self) -> Self.Item?
}

pub fit Range : Iterator {
    type Item = i64
    fn next(self: ref Self) -> i64? { ... }
}
```

### Dyn-Display

```q64
pub fn write_to_log(items: [dyn Display]) {
    for item in items {
        log.info("{item.fmt()}")
    }
}
```

## Related specs

- [`modules.md`](./modules.md) — `pub face` and `pub fit` follow the
  same visibility model as other items; cross-qube reachability is
  governed by `pub use` chains.
- [`diagnostics.md`](./diagnostics.md) — envelope format for every
  `TYP*` error listed above.
- [`qube.json5.md`](./qube.json5.md) — `effects.declared` /
  `effects.deny` interact with effect-polymorphic faces at the qube
  boundary.

## Open items deferred

- **`Arbitrary` face surface** — what the random-value generator
  interface looks like, how seeding works, how shrinking is reported.
  Lands with the test framework spec.
- **Full dyn-safety predicate** — the exact rule for which methods make
  a face non-dyn-safe; pending the compiler's vtable layout decisions.
- **Specialization of default methods** — whether a more-specific fit
  can override a default method without the more-general one being
  present. Lands with the coherence work.
- **Const-evaluated bounds** — `where N == M + 1` for const generics;
  pending the comptime spec.
