# units

The unit-of-measure spec. Dimensional analysis at compile time:
quantities carry their unit in their type, the compiler enforces
dimensional consistency, and conversions are explicit where they
need to be and free where they don't.

> **Status: draft (v0).** The blessed unit types, the literal-
> suffix table, the prefix rules, and the dimensional algebra
> below are the contract. User-defined units (`@unit`) are
> specified at a v0 surface; the open items at the end name what
> a v1 revision could expand on.

This file supersedes the placeholder table that lived in
[`types.md` §"Numeric literals and suffixes"](./types.md). The
literal-grammar form (`<number>.IDENT`) is still specified in
[`grammar.md` §Literals](./grammar.md); the semantics of which
identifiers are blessed, what type they yield, and how the values
compose live here.

## Design goals

- **Dimensional safety.** Sample-rate vs. byte-rate confusion,
  gain-vs-linear mixing, time vs. frequency mistakes — all caught
  at compile time, not at the speaker.
- **Familiar surface.** The literal forms (`48.kHz`, `-6.dB`,
  `1.MB`) read the way an audio or systems engineer already
  writes them. SI casing is honored.
- **Cheap at runtime.** A unit-tagged value is a phantom on top
  of an `f64` or `i64`; no hidden conversion, no boxed wrapper.
  Equality on the underlying scalar is the equality used by
  monomorphization (per [`generics.md`](./generics.md)).
- **Composable, not ad-hoc.** Multiplication and division of
  units obey the obvious algebra; a missing case is a compile
  error, not a silent reinterpretation.
- **A small blessed set, an open door.** v0 ships a fixed table
  of dimensions and units that the language and stdlib know
  about. User-defined units land through `@unit`; they cannot
  introduce new base dimensions in v0.

## Vocabulary

| Word          | Meaning                                                                                                       |
|---------------|---------------------------------------------------------------------------------------------------------------|
| **dimension** | An equivalence class of units that measure the same physical quantity (time, frequency, information, angle). |
| **base unit** | The canonical representative of a dimension (`s` for time, `Hz` for frequency, `byte` for information).      |
| **unit type** | A PascalCase Zig-style type name standing for a dimension: `Seconds`, `Hz`, `ByteCount`, `rad`.              |
| **suffix**    | The identifier after the dot in `48.kHz`. Names either a unit type, a prefixed unit, or a plain numeric type.|
| **prefix**    | A scale factor attached to a base unit name (`k` in `kHz`, `Ki` in `KiB`). Decimal or binary.                |
| **scalar**    | The underlying `f64` or `i64` value carried by a unit-tagged quantity.                                       |
| **dimensionless** | A unit type whose dimension is empty; arithmetic with plain numerics is permitted.                       |
| **logarithmic unit** | A unit whose addition corresponds to multiplication in the underlying linear domain (`Db`).           |

## Base dimensions in v0

The v0 lattice has six base dimensions. New dimensions are not
introducible by user code; the set is closed for v0.

| Dimension     | Symbol | Base unit | Backing scalar | Notes                                           |
|---------------|--------|-----------|----------------|-------------------------------------------------|
| Time          | T      | `s`       | `f64`          | Seconds. The duration anchor.                   |
| Frequency     | T⁻¹    | `Hz`      | `f64`          | Cycles per second. Algebraically `1/Seconds`.   |
| Information   | I      | `byte`    | `i64`          | One octet. Integer-backed (no fractional bytes).|
| Angle         | A      | `rad`     | `f64`          | Radians. Dimensionless in physics, distinct in q64 to keep `rad` and `Hz` from colliding. |
| Sample count  | N      | `sample`  | `i64`          | Discrete-step quantity used by signal pipelines.|
| Gain (log)    | G      | `Db`      | `f64`          | Logarithmic; see §"Logarithmic units".          |

`Hz` and `Seconds` are distinct dimensions in the spec, but
related by `Hz * Seconds → dimensionless` — see §"Dimensional
algebra".

## Blessed unit types

Every unit-tagged value at runtime has one of the following
nominal types. Type names are PascalCase descriptors; the
literal suffix that produces them may differ (`-6.dB` produces a
`Db`).

| Type        | Dimension     | Notes                                                                 |
|-------------|---------------|-----------------------------------------------------------------------|
| `Seconds`   | Time          | Backing `f64`. `Duration` is **not** a separate type in v0.           |
| `Hz`        | Frequency     | Backing `f64`. Inverse of `Seconds`.                                  |
| `ByteCount` | Information   | Backing `i64`. Integer count of bytes; fractional bytes are a type error. Distinct from the `Bytes<R>` collection in [`memory.md`](./memory.md), which is the byte-buffer type. |
| `Samples`   | Sample count  | Backing `i64`. Used by audio and tensor-window code.                  |
| `rad`       | Angle         | Backing `f64`. Lowercase by convention; matches the SI symbol.        |
| `deg`       | Angle         | Backing `f64`. Same dimension as `rad`; conversion is implicit (free).|
| `Db`        | Gain (log)    | Backing `f64`. Decibels — logarithmic. See §"Logarithmic units".      |
| `Semitones` | Gain (log)    | Backing `f64`. Musical pitch interval; 12 per octave.                 |
| `Cents`     | Gain (log)    | Backing `f64`. 100 per semitone.                                      |

Unit types are auto-prelude (no import). The full list above is
the contract surface; toolchain components may rely on these
identifiers being reserved.

## Literal suffixes

A numeric literal carries a unit when its suffix is a blessed
unit name or a blessed prefix + base-unit name. The lexical
grammar is fixed in [`grammar.md` §Literals](./grammar.md); this
table is the resolution policy.

| Suffix              | Yields  | Scalar applied                              |
|---------------------|---------|---------------------------------------------|
| `Hz`                | `Hz`    | value                                       |
| `kHz`               | `Hz`    | value × 10³                                 |
| `MHz`               | `Hz`    | value × 10⁶                                 |
| `GHz`               | `Hz`    | value × 10⁹                                 |
| `ns`                | `Seconds` | value × 10⁻⁹                              |
| `us`, `µs`          | `Seconds` | value × 10⁻⁶ (both spellings accepted)    |
| `ms`                | `Seconds` | value × 10⁻³                              |
| `s`                 | `Seconds` | value                                     |
| `min`               | `Seconds` | value × 60                                |
| `h`                 | `Seconds` | value × 3600                              |
| `B`                 | `ByteCount` | value                                       |
| `KB`, `MB`, `GB`, `TB` | `ByteCount` | value × 10³ⁿ (decimal multipliers)       |
| `KiB`, `MiB`, `GiB`, `TiB` | `ByteCount` | value × 2¹⁰ⁿ (binary multipliers)    |
| `sample`, `samples` | `Samples` | value (both spellings accepted)           |
| `rad`               | `rad`   | value                                       |
| `deg`               | `deg`   | value                                       |
| `dB`                | `Db`    | value (logarithmic — added, not scaled)     |
| `st`                | `Semitones` | value                                   |
| `ct`                | `Cents` | value                                       |

`48.kHz` evaluates to a `Hz` value whose underlying scalar is
`48000.0`. `1.KiB` evaluates to a `ByteCount` value whose scalar is
`1024`. The const-generic equality used by monomorphization is
the equality on those scalars: `48.kHz == 48000.Hz` is true,
including in `Signal<f32, 48.kHz>` vs. `Signal<f32, 48000.Hz>`.

A suffix that is not in the blessed table — and is not a
primitive numeric type name or an arbitrary-width int name per
[`types.md`](./types.md) — is a `UNI001` diagnostic.

## Prefixes

The prefix system is closed in v0. Only the combinations
enumerated above are valid; `1.kB` is **not** legal because the
table does not include it (the decimal-byte tradition writes
`1.KB`). The compiler does not synthesize new prefix + unit
combinations.

**Decimal (SI) prefixes** in v0: `k` (10³), `M` (10⁶), `G` (10⁹),
`T` (10¹²). Used on `Hz` and `B`. Submultiple prefixes (`m`,
`u`/`µ`, `n`) are baked into the duration row (`ms`, `us`, `ns`)
rather than being independently composable; this keeps `ms`
unambiguous (millisecond, not megasecond).

**Binary (IEC) prefixes** in v0: `Ki` (2¹⁰), `Mi` (2²⁰), `Gi`
(2³⁰), `Ti` (2⁴⁰). Used only on `B`. There is no `KiHz` —
binary prefixes on frequency are not a thing.

A v1 revision may open a more general prefix syntax. v0 is the
table.

## Dimensional algebra

Operations between unit-tagged values follow the obvious
algebra. The compiler tracks the resulting dimension; a mismatch
is `UNI010`.

| Operation          | Rule                                                                    |
|--------------------|-------------------------------------------------------------------------|
| `a + b`, `a - b`   | Same unit type required. Yields the same unit type.                     |
| `a * b`            | Dimensions multiply. `Hz * Seconds → dimensionless`. `ByteCount / Seconds → ByteCount/Seconds` (a composite). |
| `a / b`            | Dimensions subtract. `ByteCount / Seconds → ByteCount/Seconds`. `Seconds / Seconds → dimensionless`. |
| `a * k` (`k` plain)| Scalar multiplication. Yields the same unit as `a`.                     |
| `-a`               | Yields the same unit as `a`.                                            |
| `a < b`, `a == b`  | Same unit type required. Yields `bool`.                                 |
| `a.cast<U>()`      | Explicit conversion within the same dimension (e.g. `(48.kHz).cast<Hz>()` — identity at the scalar level). |

The result of `*` and `/` between distinct dimensions is a
composite unit type. Composite types are spelled with `*` and
`/` in type position:

```q64
let rate: ByteCount/Seconds = 1.MB.per.s
let area: Seconds*Seconds = (2.s) * (3.s)
```

Composite unit types are second-class in v0: they appear in
signatures and const generics, but user code cannot declare new
top-level composites with `@unit`. Stdlib introduces a small set
of named aliases (see §"Composite rate notation").

`dimensionless` is itself a unit type; a `dimensionless` value
coerces to and from the underlying scalar implicitly. `Hz *
Seconds` and `Seconds / Seconds` both produce
`dimensionless` and may be used as bare numbers.

## Conversions

Three categories, in order of friction:

1. **Within a prefix family** — `48.kHz` and `48000.Hz` are
   equal values of type `Hz`. The prefix is resolved at lex
   time; no conversion happens at the value level. Tools may
   display either form per their formatter rules.

2. **Within a dimension across types** — `rad` ↔ `deg` is
   implicit (the compiler inserts the constant). Implicit
   conversion is permitted only between the two angle types;
   every other cross-type conversion is explicit.

3. **Cross-dimension** — never implicit. A user who needs
   `Seconds` from `Samples` writes:

   ```q64
   let dur: Seconds = (samples.cast<f64>() / sample_rate.cast<f64>()).s
   ```

   or uses a stdlib helper. The compiler will not synthesize
   such a conversion; doing so would defeat the purpose of the
   spec.

## Logarithmic units

Logarithmic units (`Db`, `Semitones`, `Cents`) are a separate
algebra. Their addition corresponds to multiplication in the
underlying linear domain, and their multiplication by a scalar
corresponds to a power. The rules:

| Operation            | Meaning                                                                |
|----------------------|------------------------------------------------------------------------|
| `a + b` (both `Db`)  | Linear-domain product. `-6.dB + -6.dB == -12.dB`.                      |
| `a - b` (both `Db`)  | Linear-domain quotient. `0.dB - -6.dB == 6.dB`.                        |
| `a * k` (`k` plain)  | Linear-domain power. `-6.dB * 2 == -12.dB`.                            |
| `a / k` (`k` plain)  | Linear-domain root.                                                    |
| `a * b` (both `Db`)  | **Forbidden** — no meaningful product of two logarithmic gains. `UNI020`. |
| `a + n` (`n` plain)  | **Forbidden** — adding a plain number to a logarithmic value. `UNI021`. |

`Semitones` and `Cents` share a dimension with `Db` only in
their logarithmic character; they are not cross-convertible
without a domain choice (musical interval vs. amplitude vs.
power). Stdlib exposes `Db.to_linear() -> f64` and
`f64.to_db() -> Db` for the explicit boundary crossing.

The motivation for keeping logarithmic units in the type system
at all — instead of demanding users compute in the linear domain
— is that audio code spends most of its life in dB; making the
common path the wrong path would lose more bugs than it caught.

## Composite rate notation

The `per` chainable in stdlib builds composite rate types from a
literal-tagged base. `1.MB.per.s` parses as the literal `1` with
suffix `MB` (yielding `ByteCount`), followed by `.per.s` — a method
chain that lifts the `ByteCount` value into a `ByteCount/Seconds` rate.

```q64
let bandwidth: ByteCount/Seconds = 1.MB.per.s
let throughput: Samples/Seconds = 48000.samples.per.s
```

The composite type may also be written directly in a signature:

```q64
fn open_socket(addr: SocketAddr) -> Result<Socket, NetError>
    where Socket: Stream<Bytes, ByteCount/Seconds>
```

In dataflow positions, the same form participates in stream-rate
analysis per [`streams.md` §"Rates as units"](./streams.md). The
const-generic argument `R` to `Signal<T, R>` and `Stream<T, R>`
accepts any value of dimension Frequency or any rate composite
of the form `Quantity/Seconds`.

## Use at the type level

Unit-tagged values participate in const generics per
[`generics.md`](./generics.md). Two values of the same unit type
are equal as const-generic arguments iff their underlying
scalars are equal — `48.kHz`, `48000.Hz`, and `48_000.0.Hz` are
the same const-generic argument.

Type-position composition is permitted: `Vec3<f32, m/s²>`,
`Signal<f32, 48.kHz>`, `Tensor<f32, [N.samples, C]>`. Inside a
type, `*` and `/` between unit types build composites under the
algebra in §"Dimensional algebra"; integer exponents may be
written with the superscript digits `²` and `³` for
readability.

## User-defined units

`@unit` declares a nominal type backed by a blessed base unit.
The v0 surface is intentionally narrow:

```q64
@unit Frames : Samples       // counted by frame, scalar-equal to samples
@unit Bars  : Seconds        // musical bars (host-defined tempo turns them into seconds)
@unit Tokens : Samples       // LLM tokens, treated as a count
```

The form is `@unit Name : BlessedType`. The declared unit:

- Inhabits a new nominal type. `Frames` and `Samples` are **not**
  interchangeable; an explicit `.cast<Samples>()` is required to
  cross.
- Inherits the dimension and the scalar backing of the right-
  hand side. Operations follow the same algebra; `Frames +
  Frames → Frames`, `Frames * 2 → Frames`.
- Does **not** introduce a new literal suffix in v0. Constructing
  a `Frames` value uses `Frames(n)` or `n.cast<Frames>()`. The
  suffix table is closed.
- Cannot inherit from a composite (`@unit Bandwidth :
  ByteCount/Seconds`) in v0. A v1 revision may relax this.

`@unit` is a category-2 declaration marker per
[`annotations.md` §"Annotation categories"](./annotations.md) —
it introduces a new nominal type rather than annotating an
existing item.

## Interaction with `@kind`

`@kind` (per the design history) tags a value with a domain —
audio sample, color, identifier — and forces boundary crossings
to be explicit and named. It does **not** participate in
dimensional algebra.

- A `@kind` says "this is a thing of category X" — `PCM<f32>` is
  not interchangeable with a bare `f32`, but its arithmetic
  rules are still float arithmetic.
- A `@unit` says "this is a quantity of dimension D" — `Hz` and
  `Seconds` interact under the dimensional algebra above.

User code that needs both — an audio sample with a sample-rate
tag — composes them: `Signal<PCM<f32>, 48.kHz>` uses a kind for
the payload and a unit for the rate.

## Diagnostic codes

Unit-of-measure diagnostics use the `UNI` prefix; the codepoint
is reserved in [`diagnostics.md` §"Code conventions"](./diagnostics.md).
Numbers are stable, never reused.

| Code     | Short message                                | When                                                                              |
|----------|----------------------------------------------|-----------------------------------------------------------------------------------|
| `UNI001` | unknown unit suffix                          | A literal suffix is not in the blessed table and not a primitive type name.       |
| `UNI002` | ambiguous unit suffix                        | A suffix could resolve to multiple blessed entries (reserved; no v0 collisions). |
| `UNI010` | unit dimension mismatch                      | `1.s + 1.Hz`, or any same-operator use of two incompatible dimensions.            |
| `UNI011` | implicit unit conversion is forbidden        | A cross-dimension expression that the compiler will not auto-bridge.              |
| `UNI012` | composite unit not declarable                | A `@unit` declaration whose right-hand side is a composite type (v0 restriction). |
| `UNI020` | invalid logarithmic-unit operation           | `a * b` where both are logarithmic; product of two `Db` values is meaningless.    |
| `UNI021` | logarithmic unit mixed with plain numeric    | `(-6.dB) + 1` — no implicit interpretation as linear gain.                        |
| `UNI030` | binary prefix used outside `ByteCount`       | `5.KiHz` — binary prefixes are only valid on the `B` base.                        |
| `UNI031` | decimal-byte prefix uses wrong case          | `1.kB` or `1.mb` — the decimal byte family is uppercase (`KB`, `MB`).             |
| `UNI040` | rate composite missing time unit             | A `Quantity/Quantity` used in a rate position where the denominator must be time. |

All codes are emitted using the standard envelope from
[`diagnostics.md`](./diagnostics.md).

## Examples

### Mixing dimensions

```q64
let dur:  Seconds = 50.ms
let rate: Hz      = 48.kHz
let bad           = dur + rate           // ❌ UNI010 — Seconds + Hz
let samples       = dur * rate           // ✅ dimensionless ≈ 2400.0
```

### Byte counts, decimal vs. binary

```q64
let download: ByteCount        = 1.GB         // 1_000_000_000
let memory:   ByteCount        = 1.GiB        // 1_073_741_824
let bandwidth: ByteCount/Seconds = download.per.s
```

### Logarithmic gain

```q64
let headroom: Db = -6.dB
let stacked       = headroom + headroom   // -12.dB (linear product)
let doubled       = headroom * 2          // -12.dB (linear square)
let nope          = headroom * headroom   // ❌ UNI020
```

### User-defined unit

```q64
@unit Frames : Samples

fn frames_for(dur: Seconds, fps: Hz) -> Frames {
    let count: f64 = f64(dur) * f64(fps)   // dimensionless
    Frames(i64(count))
}
```

### Stream rate as a const generic

```q64
fn lowpass(input: Signal<f32, 48.kHz>) -> Signal<f32, 48.kHz> { … }

let pcm: Signal<f32, 48.kHz> = mic.read()
let out: Signal<f32, 48.kHz> = lowpass(pcm)    // rates match — ok
let bad                        = lowpass(    // ❌ STR021 from streams.md
    Signal<f32, 44_100.Hz>::default()        //    (rate mismatch, not UNI)
)
```

## Open items deferred

- **General prefix composition.** v0 enumerates `Hz / kHz / MHz`
  etc. as distinct table entries. A future revision may allow
  `<prefix><base>` synthesis for any blessed base.
- **Submultiple prefixes on bytes** (`mB`, `uB`). Currently not
  meaningful; deferred until a use case arrives.
- **Composite `@unit` declarations.** `@unit Bandwidth :
  ByteCount/Seconds` would let stdlib name composites. Pending
  the decision on how composite types render in diagnostics.
- **Per-unit display policy.** Whether a `ByteCount` value
  prints as `1.GB` or `1000.MB` or `1_000_000_000.B` is a
  formatter question; `fmt.md` (not yet written) is the
  eventual home.
- **Unit-aware tensor shapes.** Shape entries that carry a unit
  (`Tensor<f32, [N.samples, C]>`) work today via the const-
  generic machinery; a tighter spec for "shape arithmetic
  respects units" is deferred until `q64.math` lands.
- **Tempo and beats.** A `Bpm` unit, beats-as-`Samples`-with-
  tempo, and the conversion thereof. Music-DSP-flavored;
  belongs in a stdlib spec rather than core.
- **External-data unit annotations.** Parsing `1MB` (no dot)
  from a config file into `ByteCount`. A `qube.json5` extension,
  not a language change.

## Related specs

- [`types.md`](./types.md) — numeric tower, the literal-suffix
  grammar surface, and the placeholder table this file replaces.
- [`grammar.md`](./grammar.md) — `NUM_LITERAL` and `Suffix`
  productions; the lexical form is fixed there.
- [`generics.md`](./generics.md) — const-generic admissibility
  for unit-tagged values; equality semantics for monomorphization.
- [`streams.md`](./streams.md) — rates as units in
  `Signal<T, R>` / `Stream<T, R>` and the rate-mismatch
  diagnostics (`STR021`).
- [`annotations.md`](./annotations.md) — the `@`-form catalog;
  `@unit` is a category-2 declaration marker.
- [`diagnostics.md`](./diagnostics.md) — envelope format for the
  `UNI` code band.
