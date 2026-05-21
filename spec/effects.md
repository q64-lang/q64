# Effects

The compile-time effect system: the fixed core markers, the implication
graph between them, propagation through call graphs, integration with
[faces](./faces.md), user-defined effects, and how the registry
discloses them.

> **Status: draft (v0).** Core set, implication graph, and propagation
> rules settled. User-defined effect surface is intentionally minimal in
> v0 (opaque markers that propagate transitively); a richer model
> (sub-effects, parameterized effects) is deferred.

## Design goals

1. **Compile-time only.** Every effect is checked statically; nothing
   in this spec costs runtime. The wasm produced for an `@realtime`
   function is identical to the wasm produced for its `@pure` cousin
   minus the body — the marker is type-system metadata.
2. **A small fixed core.** A handful of blessed markers cover the
   ecosystem's needs: real-time, allocation, suspension, panic / trap,
   I/O, network, purity. Adding to the core is a language-level change,
   not a library decision.
3. **User-extensible at the leaves.** Libraries declare opaque markers
   (`@logging`, `@telemetry`, `@audit`) that propagate transitively
   but do not introduce new implication rules. The registry surfaces
   them like the core set.
4. **Inferred locally, declared at boundaries.** Inside a function
   body, the compiler infers the effect set from the calls made. At
   `pub` boundaries, face methods, and the `effects.declared` list in
   [`qube.json5`](./qube.json5.md), the set must match a declared
   contract.
5. **AI-agent friendly.** `grep '@realtime'` enumerates every
   real-time-safe entry point; `qube audit` prints the full transitive
   set per dependency; the registry shows the same set on each qube's
   detail page.

## Vocabulary

| Word              | Meaning                                                                          |
|-------------------|----------------------------------------------------------------------------------|
| **effect**        | A `@`-prefixed marker on a function, stream stage, or face method.               |
| **effect set**    | The set of effects a function carries — a function's full effect signature.      |
| **implication**   | A built-in rule that one effect entails others (e.g., `@realtime` ⇒ `@no_alloc`).|
| **assert effect** | A *negative* marker: "this function does at most …" (`@pure`, `@realtime`, `@no_*`). |
| **capability effect** | A *positive* marker: "this function may do …" (`@io`, `@network`).            |
| **observation effect** | A marker documenting that a function observes runtime state and may diverge on it (`@cancel`). Propagates up like capabilities; restricted by `@uncancellable` like an assert. |
| **effect variable** | A face-level parameter (`@e`) bound by each fit. See [faces.md §Effect-polymorphic faces](./faces.md). |

Asserts propagate **down**: an `@realtime` caller can only call
callees whose effect set is a subset of its own. Capabilities propagate
**up**: calling an `@io` callee makes the caller's effect set include
`@io`. The duality is the standard one — the rules below cover both
sides with one mechanism.

## The core effect set

The blessed core markers. Adding to this set is a language-level
change. The set splits into asserts (what the body **won't** do),
capabilities (what the body **may** do), one observation marker,
and one type-marker.

### Asserts (negative markers)

| Marker            | Meaning                                                                                       |
|-------------------|-----------------------------------------------------------------------------------------------|
| `@pure`           | No mutation, no allocation, no I/O, no suspension, no panic, no trap. The strongest assertion. |
| `@realtime`       | Bounded execution time, no allocation, no suspension, no panic. Audio-thread safe.            |
| `@no_alloc`       | No heap allocation (linear or managed).                                                       |
| `@no_suspend`     | Does not yield to the scheduler; runs to its next natural return.                             |
| `@no_panic`       | Does not invoke `panic` (`trap` remains permitted).                                           |
| `@no_trap`        | Does not invoke `trap`. Rare; "this function must complete or unwind."                        |
| `@uncancellable`  | Body completes without observing cancellation, even if `ctx` is signalled. See §`@cancel` and `@uncancellable`. |

### Capabilities (positive markers)

Each capability marker corresponds 1:1 to a capability face from
[`env.md` §"`Env` and its fields"](./env.md); the registry-level
disclosure mapping in [`env.md` §"Capability disclosure"](./env.md)
and [`qube.json5.md` §Capabilities](./qube.json5.md) is the
authoritative table.

| Marker         | Meaning                                                                            | Corresponding capability face |
|----------------|------------------------------------------------------------------------------------|-------------------------------|
| `@io`          | Catch-all I/O (devices, generic streams). Implied by every other capability below.  | (umbrella; no single face)    |
| `@network`     | Performs network operations (HTTP, WebSocket, raw sockets). Implies `@io`.          | `Net`                         |
| `@fs`          | Performs filesystem operations (read, write, list, watch). Implies `@io`.           | `Fs`                          |
| `@stdio`       | Writes to stdout or stderr. Implies `@io`.                                          | `Stdout`, `Stderr`            |
| `@audio`       | Performs audio I/O (PCM read/write, worklet operations).                            | `Audio`                       |
| `@midi`        | Performs MIDI I/O.                                                                  | `Midi`                        |
| `@ui`          | Reads UI input events; writes frames.                                               | `Ui`                          |
| `@inference`   | Performs AI model load or inference.                                                | `AiEnv`                       |
| `@time`        | Reads clock time (monotonic or wall).                                               | `Clock`                       |
| `@random`      | Reads from the system RNG.                                                          | `Rng`                         |

`@audio`, `@midi`, `@ui`, `@inference`, `@time`, and `@random` do
**not** imply `@io`: the underlying operations target dedicated
host surfaces (audio worklet, MIDI port, frame buffer, model
runtime, clock, RNG) rather than the generic-I/O streams `@io`
covers. They are peer capabilities. A function that both writes
to stdout and reads the clock declares `@stdio + @time`.

### Other markers

| Marker            | Kind        | Meaning                                                                                       |
|-------------------|-------------|-----------------------------------------------------------------------------------------------|
| `@cancel`         | observation | Function observes `ctx.cancelled()` and may unwind via `panic Cancelled`. Requires a `ctx: Cancel` parameter. See §`@cancel` and `@uncancellable`. |
| `@send`           | type-marker | A value's ownership can transfer across thread boundaries. Derived, not declared. See §`@send`. |

Notes:

- `@pure` is the only assert that forbids everything in the assert
  table. It is the "I promise this is a function in the
  mathematical sense" marker, used by stream stages, face laws,
  and `@derive` machinery.
- `@realtime` does **not** subsume `@pure` — a real-time stage may
  mutate its internal `ref self`. Real-time is about *time bounds*,
  not *purity*.
- `@no_panic` does not forbid `trap`. Audio paths use `trap()` for
  invariant violations (see [`errors.md` §`panic` and `trap`](./errors.md)).
- `@network` / `@fs` / `@stdio` imply `@io` so that callers
  declaring only `@io` may not silently leak finer-grained
  capabilities.
- A few `@realtime`-safe operations exist on otherwise-capability
  surfaces (per [`env.md` §`@realtime` and capabilities](./env.md)):
  `env.time.monotonic_ns()`, `env.random.fill_bytes(buf)` with a
  pre-allocated `buf`, `env.audio.write_pcm(buf)` on a pool-owned
  `buf`. Those specific methods are typed `@realtime + @time`,
  `@realtime + @random`, `@realtime + @audio` respectively; the
  capability marker travels with the call, but `@realtime`'s
  allocation/suspension ban still holds.

## Implication graph

The compiler treats the following implications as built-in. They
compose transitively; writing `@realtime` is shorthand for the full
expansion.

| Marker            | Implies                                                       |
|-------------------|---------------------------------------------------------------|
| `@pure`           | `@no_alloc`, `@no_suspend`, `@no_panic`, `@no_trap`, `@uncancellable` |
| `@realtime`       | `@no_alloc`, `@no_suspend`, `@no_panic`, `@uncancellable`     |
| `@no_alloc`       | `@no_panic` (panic allocates the message string)              |
| `@uncancellable`  | — (forbids `@cancel` callees by intersection)                 |
| `@network`        | `@io`                                                         |
| `@fs`             | `@io`                                                         |
| `@stdio`          | `@io`                                                         |
| `@audio`          | —                                                             |
| `@midi`           | —                                                             |
| `@ui`             | —                                                             |
| `@inference`      | —                                                             |
| `@time`           | —                                                             |
| `@random`         | —                                                             |
| `@io`             | —                                                             |
| `@no_suspend`     | —                                                             |
| `@no_trap`        | —                                                             |
| `@cancel`         | (does not imply other effects; see §`@cancel` and `@uncancellable`) |
| `@send`           | (derived from type composition; see §`@send`)                 |

Implications fan out by transitive closure: `@pure` implies
`@no_alloc`, which in turn implies `@no_panic`. A function declared
`@pure` may not `panic`, may not allocate, may not suspend, may not
`trap`, and may not perform I/O.

The runtime semantics of `panic` and `trap` (allocation, unwind,
how they propagate through scopes) are defined in
[`errors.md` §"`panic` and `trap`"](./errors.md); this spec only
governs which functions are allowed to invoke them.

A function whose declared effect set is internally contradictory
(`@realtime + @io`) is `EFF120`.

## Effect annotations on functions

Effects are written after the return type, with the same grammar used
in [`faces.md` §Method signatures](./faces.md):

```q64
pub fn dot<T: Mul<T> + Add<T>>(a: Vec3<T>, b: Vec3<T>) -> T @pure {
    a.x*b.x + a.y*b.y + a.z*b.z
}

pub fn write_log(env: Env, msg: str) @io {
    env.out("{msg}")
}

pub fn fetch(env: Env, u: Url) -> Result<Bytes, IoError> @network {
    env.net.get(u).bytes()
}
```

Multiple effects compose with `+`:

```q64
pub fn audio_step(self: ref LowPass, x: PCM<f32>) -> PCM<f32>
    @realtime + @pure
{
    // both asserts apply; intersection is the actual contract
    biquad(self, x)
}
```

A `+` between an assert and a capability is `EFF120`
(`@realtime + @io` is contradictory). Two asserts compose to their
intersection; two capabilities compose to their union.

### When to annotate

- **`pub` functions and `pub` face methods**: explicit. The contract
  is part of the qube's public surface.
- **Private functions**: optional. The compiler infers the effect set
  from the body; the inferred set is consulted whenever the function
  is called.
- **`fn main`**: implicit `@io` (programs receive `env`); explicit
  annotation is optional and informational only.

### Inference

For an unannotated function `f`:

1. Collect the effect sets of every called function in `f`'s body.
2. Take the union of those sets (capabilities) and the intersection
   of every assert that *all* callees satisfy.
3. The inferred set becomes `f`'s effect signature at every call site.

A function calling itself (direct or mutual recursion) participates
in a fixpoint pass. The compiler issues `EFF103` if the fixpoint does
not converge to a single set — in practice this happens only for
contrived examples.

## Propagation through call graphs

The single propagation rule, stated once:

> For every call `caller → callee`: the callee's effect set must be a
> subset of the caller's effect set (after closure under
> implications).

Concretely, this gives both directions:

- An `@realtime` caller cannot call an `@io` callee — `@io` is not in
  the `@realtime` set. `EFF110`.
- A caller that does not declare `@io` cannot call an `@io` callee —
  either the caller is annotated and the compiler reports `EFF111`,
  or the caller is inferred and silently picks up `@io`.

The same rule covers stream graphs. A `stage` is a function from a
scheduling perspective; stages compose by the same propagation rule.
A `@realtime` graph cannot contain a non-`@realtime` stage.

## Effects on face methods

Face method signatures may declare effects exactly as functions do:

```q64
pub face Display {
    fn fmt(self) -> str @pure
}

pub face Sink<T> {
    fn write(self: ref Self, x: T) @io
}
```

A fit's method body must satisfy the face's declared effect set. A
`@pure` face method cannot be fit with a body that calls `@io`:

```q64
pub fit Counter : Display {
    fn fmt(self) -> str @pure {
        // ❌ EFF110 — println is @io, not allowed in @pure
        println("counter is {self.count}")
        "{self.count}"
    }
}
```

Diagnostic code: `TYP211` (signature mismatch) for the structural
mismatch; `EFF110` for the underlying effect violation. Both are
emitted, with the more specific `EFF110` carrying the repair.

## Effect-polymorphic faces

The `@e` effect-variable mechanism is specified in
[`faces.md` §Effect-polymorphic faces](./faces.md). The summary:

- A face may declare effect variables: `face Filter<T, @e>`.
- A fit binds each variable to a concrete effect set:
  `fit LowPass : Filter<PCM<f32>, @realtime>`.
- Generic functions may constrain on the effect:
  `fn run_audio<F: Filter<PCM<f32>, @realtime + @no_alloc>>(...)`.

The effect-variable substitution happens before propagation. After
substitution, the rules in §Propagation apply unchanged.

## User-defined effects

Any qube may declare additional effect markers. The shape is
deliberately minimal in v0: an opaque marker that propagates
transitively, with no implications and no inference rules.

### Declaring

```q64
// in src/lib.q
pub effect @logging
pub effect @telemetry
```

`pub effect <name>` introduces a marker. Names follow `^@[a-z][a-z_]*$`
(per [`qube.json5.md` §Effects](./qube.json5.md)) and must not collide
with any core marker. A `pub effect` declaration is re-exportable via
`pub use` like any other item.

### Using

```q64
pub fn record(env: Env, evt: Event) @logging {
    env.fs.append("audit.log", evt.to_bytes())
}

pub fn process(env: Env, items: [Item]) @logging + @io {
    for item in items {
        record(env, item.as_event())     // @logging propagates
        env.out("{item}")                // @io propagates
    }
}
```

User-defined effects compose with `+` exactly like the core set.

### What user-defined effects do **not** get in v0

- **No implications.** `pub effect @audit` does not imply `@io` even
  if every existing `@audit` function happens to do I/O. Implication
  rules are reserved for the core set.
- **No inference target.** A function calling an `@audit` callee
  picks up `@audit` in its inferred set, but `@audit`-ness cannot be
  *required* by inference rules the way `@realtime` can. (User
  effects are tracked but they do not unlock or close paths.)
- **No effect-variable defaults.** Faces may use user-defined effects
  in `@e` substitutions, but the language does not synthesize
  `face`-side conveniences (like a "real-time variant" pattern) for
  user markers.

These restrictions exist so that the core implication graph stays a
language-level concern. A richer user-effect surface (sub-effects,
parameterized effects, declared implications) is deferred to a future
revision.

### Naming and collisions

User-effect names share the namespace of the core set. A qube
declaring `pub effect @realtime` is `EFF140` (shadows core). A
selective import of a user effect under a name that collides with a
core marker is `NAM005` (per
[`modules.md` §Collisions](./modules.md)).

## The `@cancel` and `@uncancellable` pair

These two markers govern cancellation observation per
[`concurrency.md`](./concurrency.md) §"Cancellation". They are a
matched pair: one declares that a function observes cancellation,
the other declares that a function cannot be interrupted by it.

### `@cancel`

A function marked `@cancel` reads `ctx.cancelled()` or calls
into another `@cancel` function, and may unwind via
`panic Cancelled` as a result. The marker is **required** when:

- The function calls `ctx.cancelled()` directly.
- The function awaits a channel `recv` / `send` on a
  cancel-aware channel policy (`Backpressure`, `LatestValue` —
  per `concurrency.md`).
- The function calls any other `@cancel` function transitively.

`@cancel` requires a `ctx: Cancel` parameter in the signature.
Declaring `@cancel` without `ctx` is `EFF160` ("`@cancel`
without `ctx` parameter").

The marker propagates **up** like a capability: a caller calling
a `@cancel` function picks up `@cancel` unless it asserts
`@uncancellable`.

```q64
fn fetch(ctx: Cancel, env: Env, url: Url) -> Result<Response, IoError> @cancel {
    if ctx.cancelled() { panic Cancelled }
    try http.get(ctx, env.net, url)
}
```

`panic Cancelled` is **not** a recoverable error; it unwinds
through the function and any enclosing `scope` per
[`errors.md`](./errors.md). The function's `Result<_, _>` return
type covers ordinary I/O failures only.

### `@uncancellable`

A function marked `@uncancellable` runs to completion (or to a
panic / trap) without observing cancellation. The body cannot
call `@cancel` functions; doing so is `CONC012` (per
`concurrency.md`) — the marker would be defeated.

```q64
fn flush_journal(env: Env, j: ref Journal) @uncancellable {
    db.write_all(env, j.pending)        // db.write_all must not be @cancel
}
```

`@uncancellable` is an assert that propagates **down**: an
`@uncancellable` caller can only call callees whose effect sets
exclude `@cancel`. The intersection rule from §"Composition"
applies — `@uncancellable + @cancel` is `EFF120` ("contradictory
effects declared").

### Interactions with other effects

- `@realtime` implies `@uncancellable` (real-time bodies don't
  observe cancellation at arbitrary points; they run to their
  next natural yield, per `concurrency.md`). `@realtime + @cancel`
  is therefore `EFF120`.
- `@pure` implies `@uncancellable` (a pure function has no
  ambient state to observe; cancellation observation would
  be a side effect).
- `@uncancellable` inside `@realtime` is flagged as redundant
  but not erroneous (`CONC013` in concurrency.md): the
  `@realtime` already implies it.

#### What "no arbitrary-point observation" means

`@uncancellable` (and therefore `@realtime`) forbids the body
from *directly* calling `@cancel` functions or
`ctx.cancelled()` mid-computation. It does **not** forbid the
implicit cancellation branch of a `select { … }` (per
[`concurrency.md` §"Implicit cancellation branch"](./concurrency.md)):
a `select` is itself a natural yield boundary, and observing
cancellation at that boundary is the audio thread's normal way
to shut down cleanly. Concretely, an `@realtime` scope's
`loop { select { … } }` pattern is well-formed; a `@realtime`
body that calls `ctx.cancelled()` between two `recv`s is `EFF110`.

### Effect set in the call graph

For a function whose effect set is inferred:

- If any direct or transitive callee is `@cancel`, the function
  picks up `@cancel`.
- If the function asserts `@uncancellable`, the same callees
  that would have added `@cancel` instead raise `CONC012` at the
  call site.

The cancellation story is **runtime-cooperative** (`h.cancel()`
sets a flag; the task observes at the next suspension or
`@cancel` check) and **statically tracked** (the effect markers
make observation visible at every signature). The runtime and
type system are aligned.

## The `@send` story

`@send` is special: it lives on types, not on functions, and the
compiler **derives** it from the type's memory composition rather than
accepting a declaration.

### Derivation rules

A type is `@send` if every component is `@send`. The base cases:

- All numeric primitives (`i8…i64`, `u8…u64`, `f16/f32/f64`, `bool`)
  are `@send`.
- A struct is `@send` iff every field is `@send`.
- An enum is `@send` iff every variant payload is `@send`.
- `Vec<T, R>` is `@send` iff `T` is `@send` and `R` is sharable or
  single-owner (per [`memory.md` §"`@send` derivation"](./memory.md)).
- Any type containing a managed (WasmGC) reference is **not** `@send`
  — the GC arena is per-Wasm-instance.

### Use sites

```q64
// Channel payload must be @send
pub fn send_frame<T: @send>(tx: Channel<T>, x: T) { tx.send(move x) }

// shared_region members must be @send
shared_region world { counter: atomic<i64> = 0 }
```

`T: @send` is the only place where `@send` appears syntactically on
user code — as a *bound* on a type parameter. Users do not write
`@send` on function signatures.

### Diagnostics

The compiler emits `EFF113` ("type does not fit `@send`") with a
secondary label pointing at the offending field. The `q64 show send
<type>` command (per [`q64-cli.md` §`q64 show` kinds](./q64-cli.md))
prints the derivation chain, terminating at the field that blocks
sendability.

## Capability disclosure surface

Effects compose with the manifest and the registry to give the
ecosystem capability-aware dependency disclosure.

### In `qube.json5`

```json5
effects: {
  declared: ["@io", "@network"],
  deny:     ["@unrestricted_fs"],
}
```

- `effects.declared` — the maximum effect set this qube's `pub`
  functions may carry, after closure under implications. A `pub`
  function whose inferred or declared effects exceed this set is
  `EFF130`.
- `effects.deny` — effects that no transitive dependency may use. A
  dependency whose effects intersect this set is `EFF131` at resolve
  time.

The compiler computes the qube's effect signature from the call graph
rooted at every `pub` item and compares it to `effects.declared`. A
declared effect not used anywhere is `EFF132` (warning, with a repair
to remove it).

### In the registry

The registry's qube detail page surfaces three fields, all derived
from the published tarball at index time:

- `effects.declared` — what the manifest lists.
- `effects.detected` — what static analysis on `pub` surface finds.
- `effects.transitive` — closure over dependencies, listed per
  contributing qube (per
  [`continuum-api.md` §Capability disclosure surface](./continuum-api.md)).

`qube audit` calls
`GET /v1/qubes/{name}/{version}/effects` and renders the same data
locally before install.

### In `qube add`

`qube add <name>` prints the resolved version's effect set before
writing to the manifest, so the user sees "this dep adds `@network`
to your transitive set" at decision time rather than at first build.

## Diagnostic codes

All effect-checking diagnostics use the `EFF` prefix. Numbers are
stable, never reused. Codes `EFF100`–`EFF103` are defined in
[`errors.md` §Diagnostic codes](./errors.md) and reproduced here for
completeness; new codes start at `EFF110`.

| Code     | Short message                                | When                                                                              |
|----------|----------------------------------------------|-----------------------------------------------------------------------------------|
| `EFF100` | `panic` in `@no_panic` function              | (Defined in `errors.md`.)                                                          |
| `EFF101` | `trap` in `@no_trap` function                | (Defined in `errors.md`.)                                                          |
| `EFF102` | `@realtime` allocates on error path          | (Defined in `errors.md`.)                                                          |
| `EFF103` | `dyn Error` in `@no_alloc` path              | (Defined in `errors.md`.)                                                          |
| `EFF104` | effect inference did not converge            | Mutually recursive functions disagree on the inferred set; user must annotate.    |
| `EFF110` | callee effect outside caller's set           | Caller declares (or infers) a set not containing a capability the callee uses.    |
| `EFF111` | undeclared capability picked up by inference | A `pub` function's inferred set exceeds its declared set.                          |
| `EFF112` | assert violated by callee                    | `@realtime` caller calls `@no_suspend`-violating callee, etc.                      |
| `EFF113` | type does not fit `@send`                    | A non-`@send` value was used where `@send` is required (channel, shared region).  |
| `EFF114` | `@send` derivation failed                    | A type's `@send`-ness cannot be derived (cyclic, opaque field, etc.).             |
| `EFF120` | contradictory effects declared               | E.g. `@realtime + @io`; capability inside an assert that forbids it.              |
| `EFF121` | unknown effect marker                        | Effect name not in scope (not a core marker, not a `pub effect` in scope).        |
| `EFF130` | declared effect set exceeded                 | A `pub` item uses an effect not in this qube's `effects.declared`.                |
| `EFF131` | dependency uses denied effect                | A resolved dep carries an effect listed in this qube's `effects.deny`.            |
| `EFF132` | declared effect unused                       | `effects.declared` lists a marker no `pub` item carries (warning).                 |
| `EFF140` | user effect shadows core marker              | `pub effect @realtime` or similar; choose a non-colliding name.                   |
| `EFF141` | invalid effect name                          | User effect name does not match `^@[a-z][a-z_]*$`.                                |
| `EFF150` | effect variable not bound                    | Fit omitted an `@e` binding the face declared.                                    |
| `EFF151` | effect variable conflicts with annotation    | `fit X : Filter<T, @realtime>` then writes `step` body as `@io`.                  |
| `EFF160` | `@cancel` without `ctx` parameter            | Function declares `@cancel` but its signature has no `ctx: Cancel`. See §`@cancel`. |

Cross-prefix codes related to `@cancel` / `@uncancellable`:

- `CONC012` (defined in [`concurrency.md`](./concurrency.md)) —
  `@uncancellable` function calls `@cancel`. Emitted by the
  effect checker; not duplicated under `EFF` to avoid two
  prefixes for the same diagnostic.
- `CONC013` (defined in [`concurrency.md`](./concurrency.md)) —
  `@uncancellable` inside `@realtime` (redundant; `@realtime`
  already implies `@uncancellable`).

All codes are emitted using the standard envelope from
[`diagnostics.md`](./diagnostics.md).

## Examples

### Audio pipeline — real-time + pure

```q64
pub face Filter<T, @e> {
    fn step(self: ref Self, x: T) -> T @e
}

pub fit LowPass : Filter<PCM<f32>, @realtime> {
    fn step(self: ref Self, x: PCM<f32>) -> PCM<f32> @realtime {
        // @realtime ⇒ @no_alloc + @no_suspend + @no_panic
        biquad(self, x)
    }
}

pub fn run_audio<F: Filter<PCM<f32>, @realtime>>(
    filter: ref F,
    input: Stream<PCM<f32>>,
) -> Stream<PCM<f32>> @realtime {
    input.map(|x| filter.step(x))
}
```

### A library that performs I/O — qube manifest

```json5
{
  name:    "log-writer",
  version: "0.1.0",
  license: "MIT OR Apache-2.0",
  effects: {
    declared: ["@io"],
    deny:     ["@network"],   // this qube must not transitively call out
  },
}
```

```q64
// src/lib.q
pub fn write(env: Env, line: str) @io {
    env.fs.append("app.log", "{line}\n".to_bytes())
}
```

A consumer adding `log-writer` sees `@io` listed in `qube audit`. If a
future version of `log-writer` accidentally pulls in a network
dependency, `qube build` fails with `EFF131` before any new code runs.

### User-defined effect — tracing

```q64
// in some qube `q64/telemetry`
pub effect @traced
```

```q64
import q64.telemetry.{traced}

pub fn submit(env: Env, payload: Bytes) @traced + @network {
    span("submit") {
        env.net.post(url"https://api.example.com/events", payload)
    }
}
```

A caller of `submit` inherits both `@traced` and `@network` in its
inferred set. The registry's effect disclosure for the calling qube
lists `@traced` next to the core markers.

### Effect contradiction

```q64
pub fn render(env: Env) @realtime + @io {     // ❌ EFF120
    // @realtime forbids @io
}
```

The repair is `id: "drop-effect"`, asking which side to keep.

### `@send` and channels

```q64
struct Frame { data: ref [u8] }       // ref into a thread-local arena

scope {
    let (tx, rx) = channel<Frame>(policy: Backpressure, capacity: 16)
    spawn { tx.send(move capture_frame()) }       // ❌ EFF113
    spawn { let f = rx.recv(); render(move f) }
}
```

`Frame` is not `@send` because `ref [u8]` points into the spawning
task's arena. The repair is `id: "copy-to-shared"`, swapping the
type for `Frame<Shared>` whose buffer lives in `mem.shared`.

## Open items deferred

- **Sub-effect ladders for user markers** (`@io.fs`, `@io.net`).
  Conceptually clean; deferred until the core set has been used
  enough in the wild to know which subdivisions matter.
- **Parameterized user effects** (`@traced<level>`). Same rationale.
- **Effect-erasure across `dyn Face`** — a `dyn Filter<T, @e>` value
  loses the `@e` substitution at the boundary. Whether the effect
  checker should track residual effects through `dyn` boxing is open
  (cross-references the
  [`errors.md` §Open items](./errors.md) entry on `dyn Error`).
- **Effect annotations on closures.** Closures inherit the enclosing
  function's effect set; explicit annotation of a closure literal is
  deferred until the closure surface itself stabilizes.
- **`@realtime` budget annotations.** Future revisions may attach a
  cycle-budget or latency bound to `@realtime` (`@realtime(< 1.ms)`).
  Out of scope for v0.
- **Effect-graph visualization in `q64 show`** — `q64 show effects
  <fn>` is specced; rendering the propagation tree as a navigable
  graph is a tooling-level extension.

## Related specs

- [`faces.md`](./faces.md) — face methods carry effects; effect-
  polymorphic faces with `@e` variables.
- [`errors.md`](./errors.md) — `@no_panic` / `@no_trap` / `@no_alloc`
  interactions with `panic` and `trap`; `EFF100`–`EFF103`.
- [`concurrency.md`](./concurrency.md) — `@cancel` and
  `@uncancellable` semantics (observation, propagation, the
  cooperative `ctx.cancelled()` mechanism); the `CONC012` /
  `CONC013` codes that the effect checker emits for
  cancellation-related violations.
- [`env.md`](./env.md) — capability faces (`Net`, `Fs`, `Audio`, …)
  whose methods carry the corresponding capability effects
  (`@network`, `@fs`, `@audio`, …) used in the disclosure mapping.
- [`modules.md`](./modules.md) — `pub effect` declarations participate
  in the standard visibility and re-export rules.
- [`qube.json5.md`](./qube.json5.md) — `effects.declared`,
  `effects.deny`, and `capabilities` manifest fields.
- [`continuum-api.md`](./continuum-api.md) —
  `GET /v1/qubes/{name}/{version}/effects` for capability disclosure.
- [`q64-cli.md`](./q64-cli.md) — `q64 show effects <fn>` and `q64
  show send <type>` introspection commands.
- [`diagnostics.md`](./diagnostics.md) — envelope format for every
  `EFF*` error listed above.
