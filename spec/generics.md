# Generics

Parametric polymorphism in q64: type parameters, const generics,
region parameters, effect variables, bounds, defaults, where
clauses, inference, and monomorphization.

> **Status: draft (v0).** Sigil and parameter kinds settled in
> [`faces.md`](./faces.md); this spec pins down the surrounding
> grammar (const generics with explicit `const`, defaults, where
> clause placement, inference rules) and the diagnostic codes.

## Design goals

1. **One sigil, one grammar.** All four parameter kinds (type,
   const, region, effect) share the `< >` brackets at both
   declaration and application sites. No turbofish, no `::<>`, no
   `.<>`.
2. **Static dispatch by default.** Generic functions monomorphize at
   compile time — zero runtime overhead, predictable `@realtime`
   reasoning, full inlining across the face boundary.
3. **Explicit kind for value-level parameters.** Const generics are
   declared with the `const` keyword so a reader never has to guess
   whether `<N: i64>` means "N is a type fitting i64" (it doesn't)
   or "N is a value of type i64."
4. **Defaults shrink the call-site surface.** Stdlib types
   (`Vec<T, R = Arena>`, `channel<T, P = Backpressure>`) shouldn't
   force every user to spell their dominant choice. Defaults are
   opt-in per parameter.
5. **AI-agent friendly.** `grep '^pub fn .*<'` enumerates every
   generic function; `grep 'where '` enumerates every constrained
   one; const generics never hide as type parameters.

## Vocabulary

| Word                  | Meaning                                                                          |
|-----------------------|----------------------------------------------------------------------------------|
| **generic parameter** | A `<…>`-bound name on a declaration. Four kinds: type, const, region, effect.    |
| **generic argument**  | The value supplied at a use site: `Vec<i64, Arena>` supplies `i64` and `Arena`. |
| **bound**             | A constraint on a type parameter: `T: Eq + Ord`. See [`faces.md`](./faces.md).   |
| **where clause**      | A trailing block of bounds, written after the signature.                          |
| **monomorphization**  | One emitted copy of a generic per concrete argument tuple. The default lowering. |

## The four parameter kinds

```q64
fn example<T, const N: i64, R: Region, @e>(
    items: [T; N],
    r: R,
) -> [T; N] @e
where T: Clone
{ ... }
```

| Kind     | Declaration syntax        | Use-site form                | Example                          |
|----------|---------------------------|------------------------------|----------------------------------|
| Type     | `Ident` or `Ident: Bound` | bare type expression         | `T`, `T: Eq + Ord`               |
| Const    | `const Ident: Type`       | bare value expression        | `const N: i64`, `const W: u32`   |
| Region   | `Ident: Region`           | a region expression          | `R: Region`                      |
| Effect   | `@Ident`                  | a `@`-prefixed marker        | `@e`                             |

Order within a `< … >` is free; convention is types first, then
consts, then regions, then effect variables — but the compiler does
not enforce ordering.

## Bounds on type parameters

Inline form with `+` composition (per [`faces.md`](./faces.md)):

```q64
pub fn dedup<T: Eq + Ord>(items: ref [T]) { ... }
```

Const, region, and effect parameters do not take face bounds. Const
parameters are bounded by their **type** (`const N: i64`); region
parameters are bounded by the auto-prelude `Region` face (per
[`memory.md` §"Region kinds"](./memory.md)) — the bound is implicit
in the `: Region` syntax and is the only bound a region parameter
can carry in v0. Effect variables are unconstrained at declaration
and unified per use-site by the fit (see
[`faces.md` §Effect-polymorphic faces](./faces.md)).

For verbose or associated-type-touching bounds, use a `where` clause.

### Implicit face parameters

A parameter whose declared type is a **face name** (with optional
generic arguments) introduces an anonymous generic parameter
bounded by that face. The two forms below are equivalent:

```q64
pub fn fetch_users(n: Net, url: Url) -> Result<[User], Error> @network {
    try n.get(url).json<[User]>()
}

// Desugars to:
pub fn fetch_users<N: Net>(n: N, url: Url) -> Result<[User], Error> @network {
    try n.get(url).json<[User]>()
}
```

Rules:

- The compiler recognises a parameter's declared type as a face
  name if it resolves to a `face` declaration in scope.
  Concrete types (structs, enums, kinds) never trigger the
  desugaring.
- Each implicit face parameter gets a fresh anonymous name; two
  parameters of the same face are **two** generic parameters
  (`fn pair(a: Net, b: Net)` desugars to `fn pair<A: Net, B: Net>(a: A, b: B)`).
  Use the explicit form if you need the two parameters to share
  a type.
- The desugared parameter is monomorphized at the call site like
  any other generic, with the same binary-size considerations
  (per §Monomorphization). Rewrite to `dyn Face` if the
  instantiation count grows past the warning threshold.
- The desugaring does **not** apply when the face is used inside
  a compound type (`fn collect(items: [Net])` keeps `[Net]` as a
  literal element type, which is `TYP200` unless `Net` itself is
  a concrete type — faces in element position need `dyn Net`).

The shorthand is the canonical form for capability-passing helpers
per [`env.md` §"Passing convention"](./env.md); the explicit
`<N: Net>` form is needed only when the same parameter shape has
to be referenced elsewhere in the signature (return type, second
parameter, where clause).

## The `where` clause

### Placement

After the signature, before the body. This is the Rust / Swift
position — bounds sit at the bottom of the declaration, leaving the
signature visually clean:

```q64
pub fn collect<I, C>(it: I) -> C
where
    I: Iterator,
    C: Collection<I.Item, _>,
{ ... }
```

The body's opening `{` follows the (possibly multi-line) `where`
block. Each comma-separated bound may stand on its own line; a
trailing comma on the last bound is permitted.

This is the canonical placement; [`faces.md`](./faces.md)'s grammar
and examples reference the rule defined here.

### When to use `where` vs inline

- Single, short bound: inline (`T: Eq`).
- Bound mentioning an associated type: `where` only.
  (`where I: Iterator, I.Item: Eq`)
- Bound on multi-parameter faces: `where` only.
  (`where Convert<A, B>, Convert<B, C>`)
- More than two bounds on one parameter: `where` for readability.

### What can appear in `where`

- Face bounds: `T: Eq`, `T: Iterator`, `Convert<A, B>`.
- Effect bounds via effect-polymorphic faces:
  `F: Filter<PCM<f32>, @realtime + @no_alloc>`.
- **Not** const-generic bounds like `where N == M + 1` — deferred to
  the comptime spec.
- **Not** lifetime / region equalities — regions are bound at the
  parameter list, not in `where`, in v0.

## Const generics

### Syntax

Const generics are declared with the `const` keyword and bound by a
**concrete type**:

```q64
pub struct Frame<const W: u32, const H: u32, Pixel> {
    pixels: [Pixel; W * H],          // simple comptime expression in shape
}

pub fn matmul<T, const A: i64, const B: i64, const C: i64>(
    a: Tensor<T, [A, B]>,
    b: Tensor<T, [B, C]>,
) -> Tensor<T, [A, C]> { ... }
```

At use sites, const arguments are bare value expressions:

```q64
type Hd1080p10 = Frame<1920, 1080, Pixel>
let m: Tensor<f32, [4, 4]> = matmul(a, b)             // A=4, B=4, C=4 inferred
```

### Permitted const-generic types

In v0:

- All integer types: `i8`–`i64`, `u8`–`u64`. Default is `i64`.
- `bool`.
- Arbitrary-width integers (`u3`, `u24`) — opt-in like everywhere
  else; useful for bit-width parameters.
- **Blessed quantity types** — the unit-tagged scalars from
  [`types.md` §"Numeric literals and suffixes"](./types.md): `Hz`,
  `Seconds`, `Db`, `B` / `KB` / `MB` / `GB` / `TB`, `KiB` / `MiB`
  / `GiB`, `rad`, `deg`. These are `f64`-or-`i64`-backed phantom-
  tagged values; the const-generic equality used by
  monomorphization is the equality on their underlying scalar.
  Used at the type level for dataflow rates (`Signal<f32, R>`
  where `R: Hz` — per [`streams.md`](./streams.md)) and similar
  units-of-measure positions. The full unit lattice lands with
  `units.md`; in the meantime, this fixed list is the contract.
- **Fixed-length arrays of the above** — `[T; N]` where `T` is
  itself a permitted const-generic type and `N` is a comptime
  integer. Used at the type level for tensor shapes:
  `Tensor<T, [N]>` (rank 1), `Tensor<T, [W, H]>` (rank 2),
  `Tensor<T, [A, B, C]>` (rank 3), etc. Equality on shape arrays
  is element-wise; concatenation and reshape arithmetic in
  `q64.math` operate on these shape values.

Not in v0 (deferred):

- Unblessed floats (`f32`, `f64`) — equality is the blocking
  concern outside the quantity types above; user code uses an
  integer encoding when it needs a non-quantity float-shaped
  const generic.
- `str` and string-like — comptime allocator and equality semantics
  unsettled.
- Variable-length arrays (`[T]` without `; N`) as const generics —
  shapes must commit to a rank at the type level. The runtime-rank
  case uses `DynTensor<T>` per
  [`types.md` §"SIMD and Tensor as language types"](./types.md).
- Custom value types (kinds, enums) — requires a `ConstParamTy`-like
  marker; deferred to a future revision.

### Const-generic expressions in shape positions

Tensor and array shapes accept arithmetic over const-generic
parameters:

```q64
pub struct Tile<const W: u32, const H: u32, const Pad: u32> {
    inner: Tensor<Pixel, [W + 2 * Pad, H + 2 * Pad]>,
}
```

The same arithmetic works in fixed-size array shapes
(`[T; N + 1]`) and in `Simd<T, const N: i64>` lane counts.

Expressions allowed in v0: `+`, `-`, `*`, `/`, `%`, comparisons,
and references to other const-generic parameters of the same item.
Operator precedence and associativity match the value-level
arithmetic grammar (multiplicative ops bind tighter than additive;
comparisons sit below both; parentheses always allowed). The
expression `W + 2 * Pad` parses as `W + (2 * Pad)`; explicit
parentheses are recommended for any expression that isn't a
trivial sum or product. Comptime function calls are deferred —
they wait for the comptime spec.

The diagnostic for "comptime expression too complex for v0" is
`TYP107`.

## Defaults on generic parameters

Defaults are allowed on any parameter kind and apply when the
argument is omitted at the use site.

```q64
pub struct Vec<T, R: Region = scope>
pub struct Map<K: Eq + Hash, V, R: Region = scope>
pub struct Box<T, R: Region = scope>

let v: Vec<i64>      = Vec.new()             // R defaults to scope's arena
let m: Map<str, i64> = Map.new()             // R defaults to scope's arena
let b: Box<i64>      = Box.new(42)           // R defaults to scope's arena
```

Region-defaulting is the most common case. Other parameter kinds
take defaults the same way; per
[`concurrency.md` §"`channel<T>(…)` construction"](./concurrency.md),
the channel constructor deliberately does **not** default its
`policy:` argument — every channel construction states its
bounded / overwriting / blocking choice (`CONC050`).

### Rules

- A parameter with a default may be omitted at use sites; the
  default is substituted.
- Parameters without defaults must appear before parameters with
  defaults in the declaration. Mixing is `TYP108`.
- A default expression may reference earlier generic parameters of
  the same declaration:
  `pub struct Pair<A, B = A>` — `B` defaults to whatever `A` is.
- A default cycle (`A = B, B = A`) is `TYP109`.

### Interaction with inference

Inference (next section) runs **before** defaults. If a missing
argument can be inferred from the value-level parameters, the
inferred value wins over the default. Otherwise the default
applies.

```q64
pub fn fill<T, const N: i64 = 16>(v: T) -> [T; N] { ... }

let a: [i64; 8]  = fill(0)              // N=8 inferred from return type
let b: [i64; 16] = fill(0)              // N defaults
```

## Inference at call sites

Inference is **aggressive**: the compiler propagates type
information bidirectionally between the call's arguments, the call's
return position, and any annotated bindings around it. A user only
spells generic arguments explicitly when the compiler reports
`TYP103` ("cannot infer generic argument") or `TYP104` ("ambiguous
generic argument").

```q64
let v: Vec<i64> = Vec.new()              // T=i64, R=Arena (default)

let d = dot([1.0, 2.0], [3.0, 4.0])      // T=f64 from the literals

let m: Mat4<f32> = matmul(a, b)          // A=B=C=4 from the binding type

let xs = collect(stream)                 // ❌ TYP103 — what's C?
let xs: Vec<i64> = collect(stream)       // ✓ C=Vec<i64>
```

### Explicit annotation when needed

Use the same `< >` brackets as the declaration:

```q64
let v = Vec<i64, Managed>.new()
let cf = Convert<PCM<i16>, PCM<f32>>.convert(sample)
```

Per [`faces.md` §"Static `Face.method` and `Face.Type` paths"](./faces.md),
the `Face<…>.method(...)` form is the canonical way to supply face
parameters explicitly. The same syntax works for generic functions
and generic types.

### Why no turbofish

Turbofish (`f::<i64>(x)`) is rejected to keep one sigil for generic
arguments at both declaration and application. The parser handles
the `<` ambiguity (generic-args vs less-than) by context-sensitive
lookahead, the same way Swift does. The trade-off is occasional
unparseable ambiguity (`a < b > (c)`), resolved by a small set of
disambiguation rules:

- A `<` immediately following an identifier that resolves to a
  generic item parses as generic-args.
- A `<` immediately following an expression of value type parses as
  less-than.
- Cases the compiler cannot resolve from context are `PAR040` with
  a repair suggesting parenthesization.

## Monomorphization

The default lowering, per [`faces.md` §"Static vs dynamic
dispatch"](./faces.md). For each call site with concrete generic
arguments, the compiler emits one specialized copy. The
implications:

- **Zero runtime overhead.** Generic calls inline like ordinary
  function calls.
- **Effect contracts hold per instantiation.** A `@realtime` generic
  function is `@realtime` at every monomorphized site.
- **Binary size scales with instantiations.** Per `faces.md`, `qube
  build` warns when a single generic exceeds N instantiations
  (default threshold N=64); for size-sensitive call sites, rewriting
  to `dyn Face` is the v0 escape hatch.
- **Identical post-monomorphization bodies are deduped** by the
  linker, per `faces.md` open items.

## What `dyn` does to generics

`dyn Face` is a *type*, not a generic argument form. A function
that takes `dyn Face` is **not** generic — it's a single emitted
copy that dispatches through a vtable.

```q64
pub fn render(target: dyn Display) { target.fmt() }      // not generic
pub fn render<T: Display>(target: T) { target.fmt() }    // generic, monomorphized
```

The dyn-safety predicate (per [`faces.md` §Dyn-safety](./faces.md))
limits which faces may appear as `dyn`. Const generics and effect
variables do **not** survive into `dyn` boxing — a `dyn Filter<T,
@e>` requires `@e` substituted at the call site:

```q64
fn run(f: dyn Filter<PCM<f32>, @realtime>) { ... }       // ✓ @e bound
fn run<@e>(f: dyn Filter<PCM<f32>, @e>) { ... }          // ❌ TYP207 — @e in dyn position
```

## v0 limitations

Explicitly out of scope for v0; tracked under "Open items deferred":

- **Higher-kinded types.** A parameter like `F<_>` (a type-level
  function) is not supported. Workaround: use associated types.
- **Variance annotations.** All type parameters are invariant in
  v0. The cases where covariance would help (read-only views) are
  rare enough to revisit later.
- **Specialization.** A more-specific impl cannot override a
  more-general one. Stdlib specialization (e.g., a faster `Vec<u8>`
  copy path) lands with the specialization spec.
- **Const-generic expression bounds.** `where N == M + 1`,
  `where N > 0`. Deferred to the comptime spec.
- **Type-level computation.** Reflection-like operations on
  parameters. Comptime spec.

## Diagnostic codes

All generics-related diagnostics use the `TYP` prefix. Numbers are
stable, never reused. Codes `TYP100`–`TYP149` are reserved for
generics; existing TYP allocations: numeric mismatch (`TYP041`),
faces (`TYP200`–`TYP219`), errors (`TYP300`–`TYP307`).

| Code     | Short message                                | When                                                                              |
|----------|----------------------------------------------|-----------------------------------------------------------------------------------|
| `TYP100` | generic argument count mismatch              | Use site supplies a different number of arguments than the declaration takes (after defaults). |
| `TYP101` | const-generic argument has wrong type        | Const arg's value type doesn't match the declared `const Ident: Type`.            |
| `TYP102` | missing required generic argument            | An argument has no default and could not be inferred.                              |
| `TYP103` | cannot infer generic argument                | Inference produced no candidate; user must annotate.                               |
| `TYP104` | ambiguous generic argument                   | Inference produced more than one candidate.                                        |
| `TYP105` | where clause not satisfied                   | A bound in the where clause is not satisfied by the concrete arguments.            |
| `TYP106` | unknown generic parameter                    | A name referenced as a generic param is not declared in this scope.                |
| `TYP107` | const expression too complex                 | Const-generic shape expression beyond v0's allowed subset.                         |
| `TYP108` | non-default after default                    | A parameter without a default follows one with a default.                          |
| `TYP109` | cycle in generic defaults                    | Defaults reference each other in a cycle.                                          |
| `TYP110` | invalid type for const generic               | Const-generic parameter declared with a type not allowed in v0 (e.g. `f64`).      |
| `TYP111` | variance annotation not allowed              | User wrote a variance annotation; not supported in v0.                             |
| `TYP112` | higher-kinded parameter not allowed          | User declared a type-level-function parameter; not supported in v0.                |
| `PAR040` | generic vs less-than ambiguity               | Parser cannot disambiguate; repair suggests parentheses.                           |

All codes are emitted using the standard envelope from
[`diagnostics.md`](./diagnostics.md).

## Examples

### Generic data type with default region

```q64
pub struct Vec<T, R: Region = scope> {
    ptr:  ref [T] @ R,
    len:  i64,
    cap:  i64,
}

pub fit Vec<T, R> : Collection<T, R> where T: Clone {
    fn push(self: ref Self, x: T) { ... }         // allocates into Self's own R
    fn pop(self: ref Self) -> T? { ... }
    fn len(self) -> i64 { self.len }
}

let a: Vec<i64> = Vec.new()                       // R = scope's arena
let b: Vec<Frame, Managed> = Vec.new()            // R = Managed
```

### Const generics in numerics

```q64
pub fn dot<T, const N: i64>(
    a: Tensor<T, [N]>,
    b: Tensor<T, [N]>,
) -> T
where T: Mul<T> + Add<T>
{
    var acc: T = T.zero()
    for i in 0..N { acc = acc + a[i] * b[i] }
    acc
}

let s = dot([1.0, 2.0, 3.0], [4.0, 5.0, 6.0])      // T=f64, N=3 inferred
```

### Inference, then default

```q64
pub fn buffer<T, const N: i64 = 16>() -> [T; N] { ... }

let a: [i64; 8]  = buffer()      // N=8 inferred from return-type binding
let b: [i64; 16] = buffer()      // N defaults to 16
let c            = buffer<i64>() // ❌ TYP102 — N has a default but T does not infer
```

### Where clause with associated types

```q64
pub fn collect_unique<I, C>(it: I) -> C
where
    I: Iterator,
    I.Item: Eq + Hash,
    C: Collection<I.Item, _>,
{ ... }
```

### Disambiguating `<` for value types

```q64
let a = 1
let b = 2

if a < b > (c) { ... }                  // ❌ PAR040 — could be generic call to `a` (not generic) or less-than chain
if (a < b) > c { ... }                  // ✓ explicit
if a < b && b > c { ... }               // ✓ uses logical operators
```

## Grammar (informal)

```
GenericParams := "<" GenericParam ("," GenericParam)* ">"
GenericParam  := TypeParam | ConstParam | RegionParam | EffectParam
TypeParam     := Ident (":" BoundList)? ("=" TypeExpr)?
ConstParam    := "const" Ident ":" TypeExpr ("=" ConstExpr)?
RegionParam   := Ident ":" "Region" ("=" RegionExpr)?
EffectParam   := "@" Ident ("=" EffectExpr)?

GenericArgs   := "<" GenericArg ("," GenericArg)* ">"
GenericArg    := TypeExpr | ConstExpr | RegionExpr | EffectExpr

WhereClause   := "where" Bound ("," Bound)* ","?
Bound         := Ident ":" BoundList                    // T: Eq + Ord
              | TypeExpr ":" BoundList                  // I.Item: Eq
              | FaceRef                                 // Convert<A, B>
BoundList     := FaceRef ("+" FaceRef)*

FnSignature   := "fn" Ident GenericParams?
                  "(" Params? ")"
                  ("->" TypeExpr)?
                  EffectSpec?
                  WhereClause?
```

The `where` clause appears **after** the signature (return type and
effect spec), **before** the body block. [`faces.md`](./faces.md)'s
grammar references this placement for `MethodSig` / `MethodDecl`.

## Open items deferred

- **Higher-kinded types.** Type-level functions as parameters.
- **Variance annotations.** Covariance, contravariance, invariance.
- **Specialization.** More-specific impls overriding more-general
  ones.
- **Const-generic bounds.** `where N == M + 1`; pending the comptime
  spec.
- **Float / string / kind const-generic types.** Pending equality,
  storage, and ConstParamTy decisions.
- **Comptime function calls in shape expressions.** Pending the
  comptime spec.

## Related specs

- [`faces.md`](./faces.md) — generic parameter syntax originated
  here; bounds, effect-polymorphic faces, dyn-safety, the
  `Face<…>.method` form.
- [`effects.md`](./effects.md) — effect variables in face
  declarations, propagation through monomorphization.
- [`modules.md`](./modules.md) — generic items follow the standard
  visibility and re-export rules; nothing generics-specific.
- [`types.md`](./types.md) — the numeric tower and primitive type
  set that const-generic parameters draw from.
- [`diagnostics.md`](./diagnostics.md) — envelope format for every
  `TYP1xx` / `PAR040` error listed above.
