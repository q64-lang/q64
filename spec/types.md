# Types

The core type system: the numeric tower, bool, arbitrary-width
integers, SIMD lane vectors, tensors, parameter modes, optional
types, and the rules that govern conversion between them.

> **Status: draft (v0).** Numeric tower and parameter modes settled
> in `design.md`, `concurrency.md`, and `memory.md`; this spec pins
> down the conversion rules (strict — no implicit promotion), the
> call-site syntax for parameter modes, optional-type flow-typing
> narrowing, and the diagnostic codes.

## Design goals

1. **No silent conversions.** Mixing numeric types (`i32 + i64`,
   `i32 + f64`, signed + unsigned) requires an explicit cast.
   Wasm doesn't promote silently; q64 doesn't either.
2. **Defaults are obvious.** `42` is `i64`. `3.14` is `f64`.
   Suffixes (`42.i32`, `48.kHz`, `-6.dB`) attach units, kinds, and
   smaller widths to literals.
3. **Parameter modes carry meaning, not call-site noise.** A
   function signature names its modes (`in`, `ref`, `out`, `move`);
   call sites are bare. The compiler still enforces mutability,
   initialization, and move semantics — the rules are signature-
   driven.
4. **Optional types narrow only when control flow makes it
   trivial.** A destructuring `if let`, or a `match` that exits the
   absent branch, narrows `T?` to `T`. No deep flow analysis in v0.
5. **AI-agent friendly.** `grep 'fn .*out '` enumerates every
   `out`-mode parameter; `grep ': u3\b'` finds bit-width work.
   Numeric types are visible at signatures, not inferred away.

## Vocabulary

| Word                | Meaning                                                                  |
|---------------------|--------------------------------------------------------------------------|
| **numeric tower**   | The fixed set of primitive number types and the rules between them.      |
| **arbitrary-width int** | An opt-in integer with non-standard bit count (`u3`, `u24`, `i17`).   |
| **literal suffix**  | A dot-delimited tag on a numeric literal (`42.i32`, `48.kHz`).            |
| **parameter mode**  | A signature-level marker (`in`, `ref`, `out`, `move`) on a parameter.    |
| **flow narrowing**  | The compiler's rule for turning `T?` into `T` after a syntactic check.   |

## The numeric tower

Fixed primitive types. Adding to this set is a language-level
change.

| Type    | Width | Signedness | Notes                                                       |
|---------|-------|------------|-------------------------------------------------------------|
| `i8`    | 8     | signed     |                                                             |
| `i16`   | 16    | signed     |                                                             |
| `i32`   | 32    | signed     |                                                             |
| `i64`   | 64    | signed     | **Default integer.** Pointers are `i64`.                    |
| `u8`    | 8     | unsigned   |                                                             |
| `u16`   | 16    | unsigned   |                                                             |
| `u32`   | 32    | unsigned   |                                                             |
| `u64`   | 64    | unsigned   |                                                             |
| `f16`   | 16    | float      | IEEE-754 half. Used for ML / tensor work.                   |
| `f32`   | 32    | float      | IEEE-754 single. Used for audio samples and SIMD lanes.     |
| `f64`   | 64    | float      | **Default float.** IEEE-754 double.                         |
| `bool`  | 8 (storage) | —      | Distinct from any integer; see §Bool.                       |

Notes:

- **No `usize` / `isize`.** q64 is 64-bit only. Pointers are `i64`
  throughout; a separate pointer-sized name would be redundant.
  Pre-spec snippets in `design.md` / `example.md` / `stdlib.md`
  that mention `usize` are obsolete; replace with `i64`.
- **`i64` is the integer default.** A literal `42` with no suffix
  or binding type has type `i64`.
- **`f64` is the float default.** A literal `3.14` with no suffix
  or binding type has type `f64`.

## Arbitrary-width integers

Opt-in for bit-level work — packed structs, protocol parsing,
register layouts, sample formats. The shape mirrors Zig's:

```q64
let nibble: u4   = 13          // 0..15
let opcode: u7   = 0b1010110   // 0..127
let signed: i17  = -65000      // -65536..65535
```

The compiler emits the masks and shifts on top of `i32` / `i64`
operations. Arbitrary-width integers cost nothing at rest in a
struct field; their cost shows up at arithmetic sites (see
§Arithmetic).

### Allowed widths

- `u1` … `u63` (unsigned, any bit width up to 63)
- `i1` … `i64` (signed, any bit width up to 64)
- Widths above 64 are not in v0; they require multi-word lowering
  and a more involved cost model.

### Naming

Arbitrary-width names follow the same `<letter><width>` shape as
the fixed-width tower (`u3`, `u24`, `i17`). Canonical code uses
the standard widths (`u8`, `u16`, `u32`, `u64`, `i8` … `i64`); the
arbitrary widths are reserved for specific bit-level scenarios.

## Bool

`bool` is a distinct type, not an integer. `if 1 { … }` is
`TYP051` ("int used as bool"); `if x { … }` requires `x: bool`.

Storage: 8 bits (1 byte) by default. Inside a struct, the
compiler may pack adjacent `bool` fields into a single byte; a
struct field declared as `u1` retains its exact 1-bit footprint
in a packed layout. Use `bool` for "yes/no" semantics, `u1` for
"a single bit in a layout."

There is **no** implicit `bool → i64` or `i64 → bool` conversion.
Use `if x { 1i64 } else { 0i64 }` explicitly when an integer
representation is required.

## Numeric literals and suffixes

A literal carries the default type if there is no suffix and no
binding-type pin:

```q64
let a = 42                    // i64 (default)
let b = 3.14                  // f64 (default)
```

A binding-type annotation overrides the default when the literal
fits:

```q64
let c: i32 = 42               // 42 typed as i32
let d: u8  = 255              // 255 typed as u8
let e: u8  = 256              // ❌ TYP040 — out of range
```

A suffix names the target type or unit explicitly:

```q64
let f = 42.i32                // i32 literal
let g = 1.u8                  // u8 literal
let h = 48.kHz                // Hz (unit; see units spec)
let i = -6.dB                 // Db (unit)
let j = 0xFF.u24              // arbitrary-width integer literal
```

The suffix form mirrors method-call syntax (`42.i32`); the
compiler recognizes the right-hand side as either a primitive
type name, an arbitrary-width int name, or a unit suffix.

**Unit suffixes recognized in v0.** Pending the full `units.md`
spec, the following suffixes are blessed by the language so other
specs may use them in examples and signatures. Each evaluates to
an `f64` value carrying a unit phantom; arithmetic between
compatible units (`s + s`, `kHz * s` → dimensionless) follows the
obvious dimensional rules.

| Suffix       | Quantity         | Base unit |
|--------------|------------------|-----------|
| `Hz`, `kHz`, `MHz`, `GHz` | frequency | Hz |
| `ns`, `us`, `ms`, `s`     | duration  | s  |
| `dB`          | gain (logarithmic) | dB |
| `B`, `KB`, `MB`, `GB`, `TB` | size (decimal multipliers) | bytes |
| `KiB`, `MiB`, `GiB`        | size (binary multipliers)  | bytes |
| `deg`, `rad`               | angle | rad |

The full unit lattice (composition rules, user-defined units,
prefix interactions) lands with `units.md`. Until then, these
suffix names are reserved and the listed semantics apply.

Float literals require a dot. `3` is `i64`; `3.0` is `f64`.
A literal like `42.kHz` is parsed as `42` followed by the
`kHz` suffix, not as a float — the suffix rule beats float
interpretation when the trailing token is an identifier.

## Bindings: `let` and `var`

Every local binding is declared with one of two keywords:

| Keyword | Mutability                | Initialization               |
|---------|---------------------------|------------------------------|
| `let`   | Immutable after init      | Required at declaration, **or** definitely-assigned before first use. |
| `var`   | Mutable                   | Required at declaration, **or** definitely-assigned before first use. |

```q64
let a: i64 = 42
let b      = 3.14            // type inferred as f64
var c: i64 = 0
c = c + 1                    // OK; var is mutable
// a = 7                     // ❌ TYP052 — assignment to `let` binding

var d: Frame                 // declared but uninitialized
if condition {
    d = Frame.uninit(1920, 1080)
} else {
    d = Frame.black()
}
use(d)                       // ✓ definitely assigned on both branches
```

Both forms accept an optional type annotation. Without one, the
compiler infers from the initializer.

### Interaction with parameter modes

The mode rules in §"Parameter modes" use these binding kinds at
call sites:

- A `ref` argument requires the caller's binding to be `var`.
- An `out` argument requires the caller's binding to be `var`;
  the binding is considered uninitialized for subsequent reads
  if `out` was the writer.
- A `move` argument may be either; the binding is consumed
  after the call regardless.

### Top-level items

`let` and `var` are local-binding keywords. Module-level constants
use `pub const`/`const` (per [`modules.md`](./modules.md) §Item
grammar); module-level mutable globals are intentionally not in
v0.

## Arrays and slices

q64 has three array-shaped types. Two are language built-ins,
one is the standard owning collection.

| Type        | Length        | Owned?          | Region parameter | Typical use                                 |
|-------------|---------------|-----------------|------------------|---------------------------------------------|
| `[T; N]`    | comptime `N`  | by value        | none (inline)    | Fixed-length arrays inside structs / locals |
| `[T]`       | runtime       | borrowed slice  | none (borrow)    | Function parameters, views into a `Vec`     |
| `Vec<T, R>` | runtime       | owns its bytes  | `R: Region`      | Growable arrays (see [`memory.md`](./memory.md)) |

### Fixed-length: `[T; N]`

`[T; N]` is a value-type array whose length is part of the type.
`N` is a comptime integer (per [`generics.md` §"Const
generics"](./generics.md)):

```q64
let id_matrix: [[f32; 4]; 4] = [
    [1.0, 0.0, 0.0, 0.0],
    [0.0, 1.0, 0.0, 0.0],
    [0.0, 0.0, 1.0, 0.0],
    [0.0, 0.0, 0.0, 1.0],
]

struct Color { channels: [u8; 4] }                  // RGBA inline

fn dot<T: Mul<T> + Add<T>, const N: i64>(
    a: [T; N], b: [T; N],
) -> T { ... }
```

Element access uses bare `[ ]`: `a[i]`. Bounds violations trap;
use `a.get(i) -> T?` for a fallible access.

### Borrowed slice: `[T]`

`[T]` is a length-tagged borrow into a contiguous run of `T`.
It is the canonical parameter type for "any sequence of `T`":

```q64
pub fn sum(xs: [i64]) -> i64 {
    var acc: i64 = 0
    for x in xs { acc = acc + x }
    acc
}

let a: [i64; 4] = [1, 2, 3, 4]
let v: Vec<i64> = Vec.from([10, 20, 30])
sum(a)                                              // ✓ [i64; 4] coerces to [i64]
sum(v.as_slice())                                   // ✓ explicit slice from Vec
```

A `[T; N]` value implicitly coerces to `[T]` (the slice records
the length at the coercion site); a `Vec<T, R>` does not — call
`.as_slice() -> [T]` to obtain a borrow. Both coercion paths are
zero-cost (no allocation, no copy).

Slices follow the same lifetime rules as any borrow (see
[`memory.md`](./memory.md) §"Lifetime tracking"): a slice cannot
outlive the bytes it points at.

### Growable: `Vec<T, R>`

The owning, growable form lives in `q64.collections` (see
[`modules.md`](./modules.md) §"Auto-prelude additions") and is
specified by `memory.md` §"Region parameters in types". `Vec`
takes a region parameter; the default is the enclosing scope's
arena.

### Slice literals

`[1, 2, 3]` is a `[T; N]` literal with `N` inferred from the
element count. When the context expects `[T]`, the literal is
materialized as `[T; N]` and coerced. When the context expects
`Vec<T, R>`, use `Vec.from([…])` explicitly — there is no
implicit promotion to an owning collection.

## References: `ref T`

A reference type is an explicit borrow that appears in type
expressions. It is **not** the same construct as the parameter
mode `ref` (per §"Parameter modes" below) — that mode controls
how an argument is passed; this type controls how a value is
held.

```q64
pub face Error : Display {
    fn source(self) -> Option<ref dyn Error> { None }
}

struct CursorMut {
    target: ref [u8],                               // a mutable slice borrow
    pos:    i64,
}

fn first_word(s: str) -> ref str {                  // borrow into s
    let space = s.index_of(' ').unwrap_or(s.len())
    s.slice(0, space)
}
```

Rules:

- `ref T` is a borrow into a value of type `T`. The compiler
  tracks the borrow's lifetime against the value's region per
  [`memory.md`](./memory.md) §"Lifetime tracking".
- Two flavors travel with the parameter mode that introduced
  them: an `in` parameter (`s: str`) yields a read-only `ref T`
  inside its body; a `ref` parameter (`ref s: Filter`) yields a
  mutable `ref T`. Mutability flows from the introducing site,
  not from a separate `ref mut` syntax.
- `ref T` cannot appear in a `@managed` struct's fields
  (`REG020`): a borrow into linear memory would escape the
  GC's reach.
- `ref T` is **not** `@send` (the borrow's region is local to
  the borrowing thread). Crossing a thread boundary requires
  `transfer(to: …)` per [`memory.md`](./memory.md).

The `&` sigil is **not** reserved; references are spelled with
the `ref` keyword in type position to match the parameter-mode
spelling. A `&` in a type expression is `LEX021` ("unexpected
character `&` in type position").

## Tuple structs

A `struct` declaration may use either the record form
(`struct Name { field: T, … }`) used throughout the spec or the
**tuple form** `struct Name(T1, T2, …)`. Tuple structs are the
spelling for newtypes and other single-purpose wrappers:

```q64
pub struct PanicMessage(str)            // wraps a single str (auto-prelude payload)
pub struct UserId(i64)                  // newtype over i64
pub struct Rgb(u8, u8, u8)              // tuple-struct with three positional fields
```

Rules:

- Construction uses positional arguments: `UserId(42)`,
  `Rgb(255, 0, 0)`.
- Field access uses `.<index>` (zero-based): `userId.0`,
  `rgb.0`, `rgb.1`, `rgb.2`.
- Tuple structs participate in the same visibility, fit,
  auto-derive, and region-parameter rules as record structs.
- A tuple-struct with one field is the canonical newtype shape
  for [`faces.md` §"Conflict resolution"](./faces.md)'s
  newtype-wrap remedy.

The two forms cannot mix in a single declaration (a struct is
either record-shaped or tuple-shaped). An empty tuple struct
`struct Name()` is **not** in v0; use the bare unit form
`struct Name` instead (as used by `Cancelled` and `Closed` in
[`errors.md`](./errors.md)).

## Strings: `str` and `String<R>`

Two string types, by intent:

| Type            | Lifetime / ownership                                     | Where it appears                                                                |
|-----------------|----------------------------------------------------------|---------------------------------------------------------------------------------|
| `str`           | Immutable slice. Borrowed; no owning region.             | Function parameters, struct fields holding read-only text, literal results.     |
| `String<R>`     | Owned, growable. Allocated in region `R` (default `Arena`). See [`memory.md`](./memory.md). | Construction, mutation, return values that must outlive the caller's borrow.    |

The relationship is the standard Rust shape: `String<R>` owns
its bytes; `str` is a borrow into someone else's bytes (a static
literal, a `String<R>`, or a slice of one). Both fit `Display`;
both interoperate with the interpolation form below.

- A plain string literal (e.g. `"Hello"`) without
  interpolation has type `str` and lives in `mem.rodata`.
- An interpolated literal (`"Hello, {name}!"`) allocates a
  fresh `String<R>` in the enclosing scope's arena, since the
  interpolation result depends on runtime values.
- `String<R>.as_str(self) -> str` borrows the owned string as a
  slice without copying (the slice's lifetime is bounded by
  `R`'s).
- `str.to_string<R>(self, r: R) -> String<R>` copies the slice
  into the named region.

There is no implicit conversion in either direction.

## String literals

String literals have three forms. All three either produce a `str`
(when the literal is a pure compile-time constant) or a fresh
`String<R>` in the enclosing scope's arena (when the form requires
runtime work, e.g. interpolation). Both fit `Display`.

### Plain interpolated form

```q64
let name = "Ada"
let greeting: str = "Hello, {name}!"             // {expr} interpolates
let escape:   str = "line one\nline two"          // \n, \t, \\, \", \0, \xHH, \u{…}
```

- Double-quoted; closes on the next unescaped `"`.
- Interpolation: `{expr}` evaluates `expr` and concatenates its
  `Display` rendering. Use `{{` and `}}` for literal braces.
- Escape sequences match Rust / Swift: `\n`, `\t`, `\r`, `\0`,
  `\\`, `\"`, `\xHH`, `\u{HHHH}`.

### Raw form (`r"…"` and `r#"…"#`)

```q64
let path = r"C:\Users\Ada\Desktop"               // no escape processing
let json = r#"{"id":42,"name":"Ada"}"#           // # delimiters allow embedded "
let big  = r##"contains "# in body"##            // any number of # pairs
```

- Prefix `r` (lowercase). Optional `#…#` pads, matched on both
  sides, let the body contain bare `"`.
- No escape processing: every character between the delimiters
  is literal.
- No interpolation: a `{` is just a brace.

### Typed-prefix form (`url"…"`, future: `re"…"`, `sql"…"`, …)

```q64
let endpoint = url"https://api.q64.dev/users/{id}"      // type: Url
let host     = url"https://api.q64.dev"                 // also Url
```

- Syntax: `<ident>"<body>"` (or `<ident>r"…"` / `<ident>r#"…"#`
  for raw bodies). The leading identifier names a `StringLit`
  fit: a comptime function on a literal-handle type that lowers
  the body to a concrete value at compile time.
- Each typed prefix is a separate, named function provided by a
  library (or the auto-prelude) — `url"…"` is provided by
  `q64.net` and surfaces in the prelude when `q64.net` is
  imported (`Env` brings it implicitly through `env.net`).
- Body interpolation follows the same `{expr}` rule as the
  plain form unless the typed prefix's `StringLit` fit declares
  it as raw.
- Unknown prefixes are `LEX020` ("unknown string-literal
  prefix").

Auto-prelude typed prefixes: a typed prefix is in the
auto-prelude exactly when its target type is reachable through
an auto-prelude capability face per
[`modules.md`](./modules.md) §"Reachable through a capability
face". `url"…"` is auto-prelude because `Url` appears in `Net`'s
signatures. Typed prefixes whose target type lives in a
non-prelude qube remain opt-in via an explicit `import`.

### Multi-line and trim rules

A double-quoted literal may span multiple source lines; each
embedded newline is preserved verbatim. For block-style literals
with leading whitespace stripped, an opening `"""` (triple-quote)
is reserved syntax — its exact trimming algorithm lands with a
future revision, alongside the comptime spec.

## Arithmetic

q64 performs **no implicit numeric conversion**. Every mix
requires an explicit cast.

```q64
let a: i32 = 1
let b: i64 = 2
let f: f64 = 1.0

let c = a + b              // ❌ TYP042 — i32 + i64
let d = a + f              // ❌ TYP042 — i32 + f64
let g = i64(a) + b         // ✓ c: i64
let h = f64(a) + f         // ✓ h: f64
```

This is the deliberate v0 stance: catches sample-rate /
buffer-size mix-ups (`i32 samples * f64 sample_rate` is a
common silent bug in other languages) at the price of more
casts in code that genuinely wants width-mixing. The
`design.md` line "Numeric promotion rules (Julia-influenced)"
is superseded by this spec.

### Casts

Every primitive type has a cast operator written as a function
call:

```q64
i32(x)        // x: any numeric → i32. Narrowing casts trap on overflow.
i64(x)        // widening or narrowing.
f32(x)        // any numeric → f32. Loses precision silently for large i64.
u8(x)         // any numeric → u8. Narrowing traps on overflow.
```

The cast is checked at runtime when the source's range exceeds
the target's. Use `try_into` (auto-prelude `TryFrom`) for
fallible casts that return `Result<T, RangeError>` instead of
trapping:

```q64
let big: i64 = 100_000
let small: i32  = i32(big)                    // narrowing; traps on overflow
let safe: Result<i32, RangeError> = big.try_into()
```

### Arithmetic on arbitrary-width integers

Arbitrary-width ints **auto-widen** to the nearest standard
width for arithmetic; assignment back to the narrower width
goes through a fallible `from`:

```q64
fn narrow(c: u32) -> Result<u3, RangeError> {
    let a: u3 = 5
    let b: u3 = 6
    let d: u3 = try u3.from(c)          // explicit narrow, fallible
    let e: u3 = u3.from_trapping(c)     // explicit narrow, traps on overflow
    Ok(d + e)
}
```

The widening target is the smallest standard width that contains
the source's value range: `u3 → u32`, `i17 → i32`, `u33 → u64`.
Signed and unsigned arb-widths widen to signed and unsigned
standard widths, respectively.

### Bool operations

Logical operators (`&&`, `||`, `!`) take `bool` operands and
short-circuit; bitwise operators (`&`, `|`, `^`, `~`, `<<`,
`>>`) take integer operands and do not short-circuit. Mixing
the two is a type error — `if x & y { … }` requires `x, y: i*`
and the result is integer, not bool.

## Parameter modes

Function parameters carry an explicit mode at the signature.
There are four:

| Mode    | Meaning                                                                       |
|---------|-------------------------------------------------------------------------------|
| `in`    | Immutable borrow. **Default**; the keyword can be omitted in signatures.       |
| `ref`   | Mutable borrow. The function may mutate the value; caller retains ownership.   |
| `out`   | Function writes; caller's prior contents are irrelevant. Must be assigned before return. |
| `move`  | Function takes ownership; caller cannot use the value after.                   |

### Signature

```q64
fn process(
    signal:     Audio,        // implicit `in`
    ref state:  Filter,
    out result: Audio,
    move payload: Bytes,
) { ... }
```

`in` is the default and is usually omitted; the other three
must appear before the parameter name.

### Call site

Calls are bare — there is **no** repeated mode keyword at the
call site:

```q64
let signal: Audio  = capture()
var state:  Filter = Filter.new()
var result: Audio  = Audio.uninit(4096)
let payload: Bytes = build_payload()

process(signal, state, result, payload)
```

The compiler enforces the mode constraints from the signature:

- `ref`: caller's binding must be `var`; not `let`.
- `out`: caller's binding must be `var`; the binding is
  considered uninitialized for the purposes of subsequent
  reads if `out` was the writer.
- `move`: caller's binding is consumed; using it after the call
  is `TYP046` ("moved value used after move").

This is a v0 simplification away from the C#-style
"call sites repeat the keyword" sketched in `design.md`. The
trade-off: bare call sites read more like ordinary function
calls; the cost is that mutability and consumption are visible
only by looking at the callee's signature (or via LSP hover).
Compiler diagnostics include the callee's mode in their
messages so the connection is recoverable from text errors.

### `out` parameters and definite assignment

A function with an `out` parameter must assign the parameter on
every control-flow path before returning. Missing an assignment
is `TYP045`. The compiler tracks definite-assignment exactly
the same way it tracks `let`-uninitialized bindings.

### Multiple `out` parameters

A function may have multiple `out` parameters. Caller
positions match the signature order:

```q64
fn split(s: str, out left: str, out right: str, at: i64) { ... }

var l: str = ""
var r: str = ""
split("hello,world", l, r, 5)
```

For functions that "return multiple values," prefer a tuple
return over multiple `out` parameters. `out` is reserved for
the rarer case where the function needs a pre-allocated
caller-provided buffer.

## Optional types and flow narrowing

`T?` is sugar for `Option<T>` (per `errors.md` §Auto-prelude
additions). The narrowing rules below describe **only** when the
compiler treats a `T?` binding as a non-optional `T` in the
subsequent code.

### When narrowing happens

1. **`if let` with a destructuring pattern**:

   ```q64
   fn use_user(user: User?) -> str {
       if let u = user {
           u.name           // ✓ u: User (narrowed)
       } else {
           "anonymous"
       }
   }
   ```

2. **`match` over the optional that exits the `None` branch**:

   ```q64
   fn require_user(user: User?) -> str {
       match user {
           None    -> return "anonymous",
           Some(u) -> u.name,     // ✓ u: User
       }
   }
   ```

3. **An early-return `if let` that exits**:

   ```q64
   fn process(user: User?) -> str {
       if let None = user { return "anonymous" }
       user.name            // ❌ TYP047 — user is still User? here
   }
   ```

   Narrowing does **not** propagate past an `if-let-None` exit in
   v0. To narrow, use the `if let Some(u) = user` form (above).

### What is **not** narrowed in v0

- `if user.is_some() { user.name }` does not narrow. The condition
  is a regular boolean; the compiler does no smart-cast analysis
  past it. Compiler emits `TYP080` (note, not error) suggesting
  the `if let Some(u) = user` form.
- Narrowing inside a closure or nested function. The narrowed
  scope ends at the closure's body boundary.
- Narrowing across `&&` chains. `if user.is_some() && user.age > 18`
  is `TYP047`; rewrite to `if let Some(u) = user { if u.age > 18 }`.

This is the deliberate v0 stance: a single, syntactic rule users
can recognize without an inference engine. Kotlin-style smart
casts are deferred; the spec may grow toward them in a later
revision.

## SIMD and Tensor as language types

Two builtin compound types live in the auto-prelude:

```q64
// Compiler builtins; declarations shown for the type-level shape only.
Simd<T, const N: i64>                          // hardware-mapped SIMD lanes
Tensor<T, const Shape: [i64; Rank], const Rank: i64>   // static-shape tensor
DynTensor<T>                                   // shape and rank carried at runtime
```

These three are **language builtins**, not user-declared types:
the compiler knows their layout, monomorphization rules, and
Wasm 3.0 lowering. The user-facing `@kind` annotation for
defining zero-cost semantic newtypes (e.g. `@kind PCM<T>`,
`@kind UserId`) is a separate construct tracked in
[`docs/history/MIGRATION.md`](../docs/history/MIGRATION.md)
as the forthcoming `kinds.md` spec; until that lands, only
these three compiler-blessed kinds exist.

The illustrative type names that appear in audio / AI examples
across the spec — `PCM<T>` (audio samples), `Token<V>` (tokenizer
output, parameterized by vocabulary), `Frame` (a video / GPU
buffer), and similar — are **ordinary user types** living in
their respective stdlib qubes (`q64.audio`, `q64.ai`,
`q64.video`). They are spelled as plain `struct`s or tuple
structs in v0; the `@kind` annotation, when it lands, will give
them a more compact zero-cost newtype spelling but does not
change what kind of declaration they are. These names are not
language builtins and are not in the auto-prelude — examples
that use them import them implicitly through the corresponding
capability face per [`modules.md` §"Reachable through a
capability face"](./modules.md).

`Tensor`'s shape parameter is a fixed-length array of `i64`
(`[i64; Rank]`) per
[`generics.md` §"Permitted const-generic types"](./generics.md);
the rank is itself a const-generic so that a `Tensor<f32, [4]>`,
`Tensor<f32, [4, 4]>`, and `Tensor<f32, [4, 4, 4]>` are three
distinct types the compiler can monomorphize cleanly. In code,
`Rank` is almost always inferred from the shape literal:
`Tensor<f32, [4, 4]>` infers `Rank = 2`.

Why they're language types, not stdlib:

- The compiler maps `Simd<f32, 4>` directly to Wasm 3.0
  `v128` lanes; lane count and lane type are part of the
  type, so codegen never has to guess.
- `Tensor<T, [W, H]>` shape participates in const-generic
  inference and the broadcasting comptime predicate that
  `q64.math` uses for elementwise ops.
- `DynTensor<T>` carries shape at runtime, for model
  weights / unknown sizes; explicit escape hatch.

Operator overloading on these (elementwise add, matmul, dot,
etc.) lives in `q64.math` per `stdlib.md`. The base language
guarantees the type kinds, the lowering, and the comptime
shape arithmetic.

### Shape expressions

The const-generic expression grammar from `generics.md`
applies to tensor shapes. `Tile<W, H, Pad>` may declare
`inner: Tensor<Pixel, [W + 2*Pad, H + 2*Pad]>`.

## Endianness

q64 is **little-endian, period.** Wasm mandates little-endian;
q64 documents it as part of the language, not as a target-
dependent fact.

External data formats (network protocols, file formats) that
are not LE are read through explicit accessors:

```q64
let value_le: u32 = bytes.read_u32_le(at: 0)
let value_be: u32 = bytes.read_u32_be(at: 4)
```

There is no system-default-endian accessor. Specifying the
endianness at the call site is part of the contract; mistakes
become localized and greppable.

## Diagnostic codes

Type-system diagnostics in the `TYP040–TYP099` band (generics
own `TYP100–TYP149`, faces own `TYP200–TYP249`, errors own
`TYP300–TYP307`). Numbers are stable, never reused.

| Code     | Short message                              | When                                                                              |
|----------|--------------------------------------------|-----------------------------------------------------------------------------------|
| `TYP040` | integer literal out of range               | A literal does not fit its declared (or pinned) type.                              |
| `TYP041` | numeric type mismatch                      | An expression of one numeric type was used where a different one was expected.    |
| `TYP042` | implicit numeric conversion is forbidden   | `i32 + i64`, `i32 + f64`, signed+unsigned mix at an arithmetic site.              |
| `TYP043` | narrowing cast may overflow                | Cast from a wider integer to a narrower one where the value isn't comptime-known. |
| `TYP044` | wrong mode for argument                    | Caller passes an immutable binding to a `ref` parameter, etc.                     |
| `TYP045` | `out` parameter not assigned before return | A function with an `out` param has a control-flow path that returns without assigning it. |
| `TYP046` | moved value used after move                | A binding consumed by a `move` argument is used after the call.                   |
| `TYP047` | optional type not narrowed                 | A `T?` binding is used as `T` outside the narrowing rules above.                   |
| `TYP048` | arb-width literal exceeds declared width   | `let x: u3 = 8` is out of `u3`'s 0..7 range.                                       |
| `TYP049` | arb-width narrow can fail                  | Assigning a standard-width value to an arb-width binding without `try <T>.from(…)` propagation.       |
| `TYP050` | `bool` used as integer                     | `let x: i32 = true` or similar.                                                    |
| `TYP051` | integer used as `bool`                     | `if 1 { … }`.                                                                      |
| `TYP052` | assignment to `let` binding                | A `let`-declared local is the LHS of an assignment after its initializing one.    |
| `TYP053` | use of uninitialized binding               | A `let`/`var` declared without an initializer is read on a path that hasn't assigned it. |
| `TYP054` | slice borrows outlive their bytes          | A `[T]` or `ref T` escapes the region whose bytes it points at.                    |
| `TYP060` | parameter mode keyword in call argument    | `process(in: x)`-style call; v0 uses bare arguments.                              |
| `TYP070` | shape mismatch in tensor op                | Shape arithmetic fails the broadcast/concat compatibility predicate.              |
| `TYP071` | SIMD lane width mismatch                   | `Simd<f32, 4> + Simd<f32, 8>` or similar.                                          |
| `TYP080` | suggestion: prefer `if let Some(u)` form   | (Note severity.) `if user.is_some()` followed by `user.method()` without narrowing.|
| `TYP090` | endianness not specified                   | An external-data read without `_le` / `_be` suffix.                                |

All codes are emitted using the standard envelope from
[`diagnostics.md`](./diagnostics.md).

## Examples

### Strict arithmetic — no silent promotion

```q64
fn beats_to_seconds(beats: i64, bpm: i64) -> f64 {
    // Need to divide an integer by a float — explicit cast required.
    f64(beats) * 60.0 / f64(bpm)
}

fn sample_count(duration: Seconds, sr: Hz) -> i64 {
    // Same-type arithmetic; no cast needed. Units-of-measure spec handles
    // the Seconds * Hz → samples reduction.
    let raw: f64 = f64(duration) * f64(sr)
    i64(raw)
}
```

### Parameter modes — signature carries the meaning

```q64
fn render(
    scene:     Scene,         // in (default)
    ref cache: RenderCache,
    out frame: Frame,
) {
    cache.update(scene)
    frame = cache.draw(scene)
}

fn main {
    var cache: RenderCache = RenderCache.new()
    var frame: Frame = Frame.uninit(1920, 1080)
    let scene = load_scene("level1.json")
    render(scene, cache, frame)
    env.out("rendered {frame.pixel_count()} pixels")
}
```

The call `render(scene, cache, frame)` reads like any function
call. The compiler enforces `cache` and `frame` being `var`
bindings and `frame` being assigned-after-call (it was `uninit`
beforehand) by consulting the signature.

### Optional narrowing — destructure or match-exit

```q64
fn greet(user: User?) {
    if let Some(u) = user {
        env.out("Hello, {u.name}!")
    } else {
        env.out("Hello, stranger.")
    }
}

fn require_age(user: User?) -> i32 {
    match user {
        Some(u) -> u.age,
        None    -> return -1,
    }
}
```

### Arb-width int arithmetic

```q64
struct OpCode {
    op:    u4,
    reg:   u3,
    flags: u1,
}

fn dispatch(code: OpCode) -> Result<(), RangeError> {
    let op:  u4 = code.op
    let reg: u3 = code.reg

    // Arithmetic auto-widens to u32; narrowing back is fallible.
    let next_op: u4 = try u4.from(op + 1)     // wraps the increment, may fail
    let _ = next_op
    Ok(())
}
```

## Open items deferred

- **Numeric promotion convenience knob.** A future revision may
  introduce an opt-in `@auto_promote` annotation that re-enables
  Julia-style implicit promotion within a body. For now: explicit
  casts everywhere.
- **`@auto_promote` for struct field initializers.** Same idea
  scoped to a struct literal.
- **Per-field visibility on structs.** Cross-references the
  `modules.md` and `faces.md` deferral.
- **Tensor broadcasting predicate.** The exact comptime rules for
  shape compatibility (NumPy / Julia conventions); lives in
  `q64.math`'s spec when written.
- **Bool ↔ integer conversions.** Whether `bool.into_i64()` is in
  the prelude; for now, use `if b { 1i64 } else { 0i64 }`.
- **Conditional flow-typing inside `&&` chains.** Kotlin-style
  smart casts; pending real-world demand evidence.

## Related specs

- [`faces.md`](./faces.md) — `Eq`, `Ord`, `From`, `TryFrom` faces
  for numeric conversion; `Display` / `Debug` for diagnostics.
- [`errors.md`](./errors.md) — `Option<T>` enum, `?` chaining,
  `try` propagation, `Result<T, E>`.
- [`generics.md`](./generics.md) — const generics, the four
  parameter kinds, the where clause that bounds in this spec
  reference.
- [`effects.md`](./effects.md) — arithmetic and casts are
  `@pure`-compatible; `try_into` is `@no_panic`-compatible.
- [`modules.md`](./modules.md) — primitive types and `Option` /
  `Result` are in the auto-prelude; no import required.
- [`diagnostics.md`](./diagnostics.md) — envelope format for the
  `TYP040`–`TYP099` codes.
- [`memory.md`](./memory.md) — region parameters that types may
  take; the dual-heap interaction with `@send`.
- *Forthcoming*: [`units.md`](./units.md) — the full units lattice
  (composition, user-defined units). Until it lands, the suffix
  table in §"Numeric literals and suffixes" is the contract.
