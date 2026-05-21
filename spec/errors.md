# Errors

How q64 expresses fallible computation: `Result<T, E>` as the core
type, `try` for propagation, `panic` / `trap` for fatal bugs, and
`Option<T>` for absence (distinct from error).

> **Status: near-final (v0).** Names settled (`try`, `panic`, `trap`);
> `Error` face surface settled; `From`-based propagation conversion
> settled; `panic` carries a typed payload via the `Panic` face. Some
> surface details (multi-error function patterns, stack-trace policy)
> firm up with implementation.

## Design goals

1. **Recoverable errors are values.** Every recoverable failure goes
   through `Result<T, E>` — declared in the return type, propagated
   with `try`, never silently unwound. Unrecoverable conditions
   (broken invariants, cancellation, runtime denials) unwind via
   `panic` with a typed payload; the unwind path is explicit, visible
   at signatures (via `@no_panic`), and catchable only at `scope`
   boundaries.
2. **Propagation is explicit and greppable.** `grep '\btry\b'` finds
   every fallible call site; `grep '\bpanic\b'` finds every typed
   unwind. No silent unwinding, no hidden `?` postfix.
3. **The audio thread is panic-free.** `@realtime` implies `@no_panic`.
   Recoverable errors use `Result`; unrecoverable invariants use `trap`
   (no allocation, no unwind).
4. **Optional absence is not failure.** A missing value is `Option<T>`;
   a *failed* attempt to produce a value is `Result<T, E>`. The two are
   distinct types, distinct error vocabulary.
5. **AI-friendly serialization.** `Result<T, E>` and the diagnostic
   envelope both serialize to the same shape used by Vercel Zero and
   the modern AI-SDK pattern: `{ ok, value? | error? }`.

## Vocabulary

| Word        | Meaning                                                                  |
|-------------|--------------------------------------------------------------------------|
| `Result<T, E>` | Tagged union — either `Ok(T)` or `Err(E)`.                            |
| `Option<T>` / `T?` | Tagged union — either `some(T)` or `none`. Sugar: `T?` ≡ `Option<T>`. |
| **try**     | Prefix keyword; propagates `Err` to the enclosing function.              |
| **panic**   | Structured user-level unwind with a typed payload (fits `Panic`).        |
| **trap**    | Bare Wasm trap. Immediate halt, no payload, no unwind, no allocation.    |
| **Error**   | Face that error types implement (`Display` + optional `source()`).        |
| **Panic**   | Face that panic-payload types implement (`Display` + optional `code()`).  |

## Result and Option

Both live in the language auto-prelude (per
[`modules.md`](./modules.md) §Forbidden — auto-prelude); no import
needed.

```q64
pub enum Result<T, E> {
    Ok(T),
    Err(E),
}

pub enum Option<T> {
    some(T),
    none,
}

pub type T? = Option<T>          // sugar
```

Constructor casing matches the convention from `example.md` (`Ok` /
`Err` capitalized, `some` / `none` lowercase to match their use as
sentinels).

## The `try` keyword

Prefix form. Reads "try this fallible call; if it errs, propagate."

```q64
pub fn read_config(env: Env) -> Result<Config, IoError> {
    let bytes        = try env.fs.read("config.json")
    let cfg: Config  = try bytes.json()
    Ok(cfg)
}
```

### Semantics

For `try expr` where `expr` evaluates to `Result<T, E1>` and the
enclosing function returns `Result<U, E2>`:

1. If `expr` is `Ok(v)`, the `try` expression yields `v` (a `T`).
2. If `expr` is `Err(e1)`, the enclosing function returns
   `Err(E2.from(e1))` immediately. The conversion uses the
   auto-prelude `From` face — that is, `fit E2 : From<E1>` must be
   reachable; otherwise the compiler emits `TYP301`.

### Type-system rules

- `try` is only valid inside a function returning `Result<_, _>`.
  Using it elsewhere is `TYP300`.
- The compiler infers the source error type `E1` from `expr` and the
  target error type `E2` from the enclosing return signature, then
  requires `fit E2 : From<E1>` (or `E1 == E2`).

### Why a keyword, not a sigil

`try` reads at the start of every fallible call site — the line begins
with the visible intent. `?` is shorter but trails behind the value
expression; readers (and agents) often miss it on long lines. The
trailing-`?` form is **forbidden** on `Result` — there is one canonical
way to spell "propagate an error": `try`. Postfix `?` is reserved for
the `?.` chain operator on `Option<T>` (see "Question-mark chaining on
`Option`," below); a bare `?` on a `Result` value is `TYP305`
("`?` on `Result`; use `try`").

### Variants deferred

Swift has `try?` (convert error to `Option`) and `try!` (panic on
error). q64 does not include either in v0. The same effects are
achievable with explicit code:

```q64
let maybe: T?  = match fallible() { Ok(v) -> some(v), Err(_) -> none }   // ≈ try?
let v:     T   = fallible().unwrap_or_panic()                            // ≈ try!
```

If these patterns become idiomatic in practice, a future spec revision
can introduce `try?` and `try!` without breaking the v0 surface.

## `panic` and `trap`

Two ways to abort. Different costs, different use cases.

### `panic <payload>` — structured unwind with a typed payload

```q64
panic "invariant broken: count went negative; got {count}"   // string payload
panic Cancelled                                              // unit-struct payload
panic RuntimeDenied { code: "ENV030", detail: "Net.get(…)" } // struct payload
```

- `panic <expr>` unwinds the current task, attaching `expr` as the
  payload. `expr`'s type must fit the `Panic` face (§"The `Panic`
  face" below); the compiler enforces this at `panic` sites.
- `panic "msg"` is sugar for `panic(PanicMessage("msg"))`, where
  `PanicMessage` is an auto-prelude struct fitting `Panic`. String
  interpolation works as in any string literal.
- The payload allocates in the current scope's arena (per
  `concurrency.md`). String panics allocate the message; typed
  panics allocate the payload value.
- Unwinding tears down scoped allocators, cancels sibling tasks in
  the enclosing `scope`, and propagates to the parent scope. The
  program exits with code 1 if uncaught at the top level (or with
  the payload's `code()` mapped to an exit, when defined — per
  `q64-cli.md`).
- Carries an effect: `panic` requires the surrounding function to
  *not* be `@no_panic` (which would be `EFF100`).
- Re-raising inside `catch`: `panic e` where `e: Panic` (or any type
  fitting `Panic`) unwinds with the same payload — there is no
  separate `raise` or `rethrow` keyword.

Use when: an invariant the developer believed to hold has been
violated, a runtime check fires (`ENV030`, cancellation), or a
non-recoverable condition needs to escape to the nearest `scope ...
catch` — and no meaningful in-line recovery is possible.

### `trap()` — bare Wasm trap, no unwind

```q64
trap()                       // no message, no allocation, immediate halt
```

- Emits the Wasm `unreachable` instruction (or equivalent).
- No string, no allocation, no unwind.
- No `panic` payload to inspect.
- The host engine halts the wasm module. Browser tab keeps running;
  worker thread terminates; Wasmtime / Wasmer return their respective
  "trapped" status.
- Carries an effect: `trap` requires the surrounding function to *not*
  be `@no_trap`.

Use when: the path "should be physically impossible to reach" and
allocating a panic message itself would violate the function's effect
contract — most commonly on the audio thread inside `@realtime` /
`@no_alloc` paths.

### Effect interactions

| Effect      | Allows `panic`? | Allows `trap`? | Notes                                                                |
|-------------|-----------------|----------------|----------------------------------------------------------------------|
| `@no_panic` | ❌               | ✅              | `panic` is rejected; `trap` is fine (no allocation).                  |
| `@no_trap`  | ✅               | ❌              | Rare; "this function must complete or unwind."                       |
| `@no_alloc` | ❌               | ✅              | `panic` would allocate the message — rejected.                       |
| `@realtime` | ❌               | ✅              | Implies both `@no_panic` and `@no_alloc`; `trap` remains available.  |
| `@pure`     | ❌               | ❌              | Pure functions can't terminate the program via either mechanism.     |

Audio paths typically use `trap()` for invariant violations and
return silence / last-known-good for recoverable conditions. They
never `panic`.

## The `Error` face

```q64
pub face Error : Display {
    fn source(self) -> Option<&dyn Error> { none }      // default: no inner error
}
```

- **Required**: implement `Display` (i.e., `fn fmt(self) -> str @pure`).
- **Optional**: override `source()` to expose an inner error, enabling
  chain-of-causes display.
- The face is in the auto-prelude.

### Example: an error type with source chain

```q64
pub enum LoadConfigError {
    Io(IoError),
    Parse(JsonError),
}

pub fit LoadConfigError : Display {
    fn fmt(self) -> str {
        match self {
            Io(_)    -> "failed to load config from disk",
            Parse(_) -> "failed to parse config",
        }
    }
}

pub fit LoadConfigError : Error {
    fn source(self) -> Option<&dyn Error> {
        match self {
            Io(e)    -> some(&e),
            Parse(e) -> some(&e),
        }
    }
}
```

A diagnostic-printer like `qube run` walks the source chain:

```
error: failed to load config from disk
caused by: no such file or directory: ./config.json
```

### Why a face, not duck-typing

- **Grep-ability.** `grep '^pub fit .* : Error'` enumerates every
  error type in the qube. Critical for AI agents auditing failure
  modes.
- **Auto-derive opportunity.** A future revision can auto-derive
  `Error` from any type whose variants are themselves errors, in the
  same way `Eq` and `Hash` are auto-derived today.
- **Capability disclosure.** The registry's effect surface
  (`continuum-api.md` §"Capability disclosure surface") can in
  principle list "what error types this qube introduces" alongside
  declared effects.

## The `Panic` face

`panic` accepts a typed payload; any type fitting the `Panic` face is
a legal payload.

```q64
pub face Panic : Display {
    fn code(self) -> Option<str> { none }      // default: no diagnostic code
}
```

- **Required**: implement `Display` (`fn fmt(self) -> str @pure`).
- **Optional**: override `code()` to expose a stable string tag that
  diagnostics, log formatters, and the runtime's exit-code mapping can
  match on (e.g. `"ENV030"`, `"CONC012"`).
- The face is in the auto-prelude.

### Auto-prelude payload types

The language ships four blessed `Panic`-fitting types:

| Type            | Shape                                  | Where it comes from                                                      |
|-----------------|----------------------------------------|--------------------------------------------------------------------------|
| `PanicMessage`  | `struct PanicMessage(str)`             | `panic "string"` desugars to `panic(PanicMessage(s))`.                    |
| `Cancelled`     | `struct Cancelled`                     | Cancellation observation in `@cancel` functions; the implicit `select` cancellation branch; cancel-aware channel ops. `code()` returns `none` (cancellation is a runtime control-flow event, not a diagnostic). |
| `Closed`        | `struct Closed`                        | A blocking `recv(ctx)` on a closed-and-empty channel (per [`concurrency.md` §"`Sender<T, P>` and `Receiver<T, P>` API"](./concurrency.md)). `code()` returns `none`. |
| `RuntimeDenied` | `struct RuntimeDenied { code: str, detail: str }` | Runtime-emitted denials such as `with_capabilities` (`ENV030`). The `code` and `detail` fields back the values seen on `Panic`-bound catch variables. |

All three are in the auto-prelude (no import required). User code may
define additional `Panic`-fitting types freely:

```q64
pub struct ParseLimitExceeded {
    file:  str,
    bytes: i64,
}

pub fit ParseLimitExceeded : Display {
    fn fmt(self) -> str { "parse limit exceeded in {self.file} ({self.bytes} bytes)" }
}
pub fit ParseLimitExceeded : Panic {
    fn code(self) -> Option<str> { some("PARSE_LIMIT") }
}
```

### Catch syntax

A `scope { … } catch { … }` block binds the panic payload by type
(per [`concurrency.md` §"Panics across tasks"](./concurrency.md)).
Two forms:

```q64
scope { … } catch (e: Panic) { … }            // catch-all; e is dyn Panic
scope { … } catch (e: Cancelled) { … }        // typed; only this payload type
```

- `catch (e: Panic)` binds `e: dyn Panic`. Inspect via `e.fmt()`,
  `e.code()`, or by `match e { c: Cancelled -> …, _ -> … }`-style
  type-test patterns (forthcoming, per `concurrency.md`'s "Open
  items deferred").
- `catch (e: T)` for a concrete `T: Panic` matches only when the
  payload's runtime type is `T`; non-matching panics propagate to the
  enclosing scope.
- Multiple `catch` arms after one `scope` are supported (most
  specific to least specific); see `concurrency.md`.
- Re-raising: `panic e` inside `catch (e: …)` unwinds with the same
  payload, propagating to the enclosing scope.

### Why a face, not a sealed type

- **User extensibility.** Library code defines its own panic payload
  types — `ParseLimitExceeded`, `ShaderCompileError`, `AssertFailure`
  — without modifying a closed enum.
- **Greppable.** `grep '^pub fit .* : Panic'` enumerates every
  panic-payload type in the qube, the same way `Error` is greppable.
- **Capability disclosure.** A qube's set of declared `Panic` types
  is part of its public surface; the registry surfaces it
  alongside `effects.declared`.

### The `Error → Panic` bridge

Any type fitting `Error` auto-fits `Panic` via a compiler-synthesized
blanket fit:

```q64
// Conceptual; the compiler generates this automatically for every Error type.
pub fit T : Panic where T: Error {
    fn fmt(self) -> str { Error.fmt(self) }
    fn code(self) -> Option<str> { none }
}
```

Consequences:

- `panic e` is well-typed for any `e` whose type fits `Error` —
  applications can convert a recoverable failure into a fatal one
  without writing a separate `Panic` fit.
- Stage error propagation (per [`streams.md` §"Error
  propagation"](./streams.md)) and `main` Form 1 (per §"`main`
  signature" in [`env.md`](./env.md)) rely on this bridge.
- The bridge is a blanket fit, **not** a conversion: the panic
  payload's runtime type is the original error type. A `catch (e:
  IoError)` arm matches the original `IoError`; a `catch (e: Panic)`
  arm sees it through the `Panic` face.
- The bridge can be **shadowed** by an explicit `fit T : Panic { … }`
  on a specific error type when the default `Error.fmt` /
  `none`-coded behavior isn't right; this is the conventional
  override path. Two competing fits (the bridge and an explicit
  one) resolve in favor of the explicit fit (per `faces.md`'s
  coherence rules).

## Multi-error functions

Three idioms, in increasing order of escape-hatch-ness:

### Library style — define an enum

```q64
pub enum ReadJsonError {
    Io(IoError),
    Parse(JsonError),
}

pub fit ReadJsonError : From<IoError>   { fn from(e: IoError)   -> Self { Io(e)    } }
pub fit ReadJsonError : From<JsonError> { fn from(e: JsonError) -> Self { Parse(e) } }

pub fn read_json<T>(env: Env, path: Path) -> Result<T, ReadJsonError> {
    let bytes  = try env.fs.read(path)        // IoError    -> ReadJsonError via From
    let value: T = try bytes.json()           // JsonError  -> ReadJsonError via From
    Ok(value)
}
```

The `From` impls glue the two error kinds together. This is what
library code should do — precise error types let callers match on
specific failures.

### Inline sum type — anonymous union

```q64
pub fn read_json<T>(env: Env, path: Path) -> Result<T, IoError | JsonError> {
    let bytes    = try env.fs.read(path)
    let value: T = try bytes.json()
    Ok(value)
}
```

`E1 | E2` is sugar for an anonymous tagged union; the compiler
generates the same code as the enum form. Useful when the error type
is local and naming it adds no value.

### Application style — `dyn Error`

```q64
pub fn run(env: Env) -> Result<(), dyn Error> {
    let cfg = try read_config(env)
    let _   = try connect_db(cfg)
    let _   = try serve(env)
    Ok(())
}
```

Boxes any error type satisfying the `Error` face. One return type
fits all failure modes. Pays one allocation per error construction;
acceptable in application code, not on `@realtime` paths.

### Recommendation

- Libraries: precise enum or `E1 | E2` inline union.
- Application top-level: `dyn Error` is fine.
- Real-time / `@no_alloc`: precise enum only; `dyn Error` boxing is
  rejected by the effect checker.

## Question-mark chaining on `Option`

The `?.` postfix operator chains through `Option<T>`:

```q64
let first_name: str? = user?.profile?.name
```

Equivalent to:

```q64
let first_name: str? = match user {
    none    -> none,
    some(u) -> match u.profile {
        none    -> none,
        some(p) -> some(p.name)
    }
}
```

`?.` is the only `?`-sigil form in user code. `?` does *not* appear on
`Result` — that uses `try`.

## Destructure form (`example.md` sugar)

```q64
let (obj, err) = env.net.get(url).json()
if let e = err { return e }
// obj is non-none here by flow typing
```

Sugar over `Result<T, E>`:

- `let (x, y) = expr` where `expr: Result<T, E>` binds:
  - `x: Option<T>`
  - `y: Option<E>`
  - With the invariant: exactly one is `some`.
- After `if let e = err { return ... }`, the flow-typer narrows
  `obj` from `Option<T>` to `T` on the fall-through path.

This is the same shape as the `{ ok, result, error }` JSON envelopes
used by Vercel Zero, the AI SDK, and modern API conventions — a q64
`Result<T, E>` round-trips cleanly to JSON:

```json
{ "ok": true,  "value": {...} }
{ "ok": false, "error": {...} }
```

`@derive(ToJson)` on a `Result<T, E>` (where `T: ToJson, E: ToJson`)
produces this envelope.

## Diagnostic codes

Error-handling diagnostics. Type-checking concerns fall under `TYP*`;
effect-system concerns under `EFF*`.

| Code     | Short message                                | When                                                                            |
|----------|----------------------------------------------|---------------------------------------------------------------------------------|
| `TYP300` | `try` requires `Result` return type          | `try` used in a function whose return type is not `Result<_, _>`.               |
| `TYP301` | error conversion not available               | `try` needs `fit TargetError : From<SourceError>`; no such fit is reachable.    |
| `TYP302` | non-exhaustive match on `Result`             | A `match` over `Result` doesn't handle both `Ok` and `Err`.                     |
| `TYP303` | `?.` on non-`Option` value                   | `?.` chain operator used on a value whose type is not `Option<T>`.              |
| `TYP304` | mismatched arms in destructure form          | `let (x, y) = expr` where `expr` is not a `Result<_, _>`.                       |
| `TYP305` | `?` postfix on `Result`                      | Bare `?` used on a `Result` value; use the `try` prefix instead.                |
| `TYP306` | `panic` payload does not fit `Panic`         | The value passed to `panic` is not a `str` and its type does not fit `Panic`.   |
| `TYP307` | `catch` type is not `Panic`-fitting          | `catch (e: T)` where `T` is neither `Panic` itself nor a type fitting `Panic`.  |
| `EFF100` | `panic` in `@no_panic` function              | `panic …` invoked from a function declared (or transitively required) `@no_panic`. |
| `EFF101` | `trap` in `@no_trap` function                | `trap()` called from a function declared `@no_trap`.                            |
| `EFF102` | `@realtime` function calls fallible operation that allocates on error | `@realtime` cannot construct heap-allocated `Err` values. |
| `EFF103` | `dyn Error` in `@no_alloc` path              | Boxing an error allocates; rejected on `@no_alloc` paths.                       |

## Auto-prelude additions

The error-handling auto-prelude (no import needed):

| Name           | Kind   | Provides                                         |
|----------------|--------|--------------------------------------------------|
| `Result`       | enum   | `Ok(T)`, `Err(E)`                                |
| `Option`       | enum   | `some(T)`, `none`                                |
| `T?`           | sugar  | `Option<T>`                                      |
| `try`          | keyword| `Result` propagation                             |
| `panic`        | keyword| typed-payload structured unwind                  |
| `trap`         | fn     | bare wasm trap                                   |
| `Error`        | face   | the recoverable-error contract                   |
| `Panic`        | face   | the panic-payload contract                       |
| `PanicMessage` | struct | wraps a `str` payload for `panic "msg"` sugar    |
| `Cancelled`    | struct | unit payload signalling cooperative cancellation (per `concurrency.md`); `code()` returns `none` (cancellation is a runtime control-flow event, not a diagnostic) |
| `Closed`       | struct | unit payload for blocking `recv(ctx)` on a closed-and-empty channel (per `concurrency.md`); `code()` returns `none` |
| `RuntimeDenied`| struct | payload for runtime denials (e.g. `with_capabilities` `ENV030`); fields `code: str`, `detail: str` |
| `From`         | face   | error conversion target (already in prelude)     |
| `Into`         | face   | error conversion source (already in prelude)     |
| `RangeError`   | struct | error returned by `try_into` casts (see [`types.md` §Casts](./types.md)) when a numeric value does not fit the target width. One field: `value: i64`. Fits `Error`, `Display`, `Debug`. |

## Examples

### Reading a config

```q64
pub enum ConfigError {
    Io(IoError),
    Parse(JsonError),
}

pub fit ConfigError : From<IoError>   { fn from(e: IoError)   -> Self { Io(e)    } }
pub fit ConfigError : From<JsonError> { fn from(e: JsonError) -> Self { Parse(e) } }

pub fit ConfigError : Display {
    fn fmt(self) -> str {
        match self {
            Io(_)    -> "couldn't read config from disk",
            Parse(_) -> "config file is malformed",
        }
    }
}

pub fit ConfigError : Error {
    fn source(self) -> Option<&dyn Error> {
        match self { Io(e) -> some(&e), Parse(e) -> some(&e) }
    }
}

pub fn load_config(env: Env, path: Path) -> Result<Config, ConfigError> {
    let bytes        = try env.fs.read(path)
    let cfg: Config  = try bytes.json()
    Ok(cfg)
}
```

### Application top-level

```q64
fn main(env: Env) {
    match load_config(env, "config.json") {
        Ok(cfg) -> serve(env, cfg),
        Err(e)  -> env.exit(1, "{e.fmt()}"),
    }
}
```

### Audio path — uses `trap`, never `panic`

```q64
pub fit LowPass : Filter<PCM<f32>, @realtime> {
    fn step(self: ref Self, x: PCM<f32>) -> PCM<f32> @realtime {
        if self.state == Broken { trap() }      // ✓ trap is allowed in @realtime
        // if self.state == Broken { panic("…") }  // ✗ EFF100: @realtime is @no_panic
        biquad(self, x)
    }
}
```

### Option chaining

```q64
struct User    { profile: Profile? }
struct Profile { name: str? }

fn greet(env: Env, user: User?) {
    match user?.profile?.name {
        some(n) -> env.out("Hello, {n}!"),
        none    -> env.out("Hello, stranger."),
    }
}
```

## Open items deferred

- **`try?` and `try!` shortcuts** — pending real-world evidence that
  the longhand match / `unwrap_or_panic` is too verbose.
- **Stack traces in `panic`** — today the payload is the only carried
  state. A future revision may attach a captured backtrace alongside
  the payload (cost: ~few kB per panic; opt-in via `@traced_panic`).
- **Type-test patterns in `catch (e: Panic)` arms** — destructuring a
  `dyn Panic` by concrete type inside one catch body. Currently
  expressible by an outer `catch (e: Panic)` plus a sequence of
  typed catches; sugar for combined arms is deferred per
  `concurrency.md`.
- **Automatic `From` derivation between sub-enums** — manually
  writing `fit ReadError : From<IoError>` is repetitive. A
  `@derive(From)` for enum wrappers may land later.
- **Effect erasure across `dyn Error`** — a `dyn Error` value
  technically erases the source error's effects. Whether the effect
  checker should track residual effects through `dyn` boxing is open.

## Related specs

- [`diagnostics.md`](./diagnostics.md) — toolchain-side diagnostic
  envelope (different from user-program `Result<T, E>`).
- [`faces.md`](./faces.md) — `Error`, `Panic`, `From`, `Into`,
  `Display` faces.
- [`modules.md`](./modules.md) — auto-prelude listing including these
  new entries.
- [`q64-cli.md`](./q64-cli.md) — `q64 explain <code>` to look up any
  `TYP*` / `EFF*` / `ERR*` code documentation.
- [`qube-cli.md`](./qube-cli.md) — `qube fix --plan` / `qube fix --apply`
  to drive automated repair from the `repair` field of diagnostics.
