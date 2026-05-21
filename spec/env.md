# Environment & Capabilities

The capability surface. How a q64 program reaches the outside
world — network, filesystem, audio, time, random, UI — and how
it doesn't reach anything it wasn't given.

q64's I/O model is **passed, not ambient**. There is no global
`stdout`, no global `Date.now()`, no global `fetch()`. Every
side-effecting operation goes through a capability value the
program received from its caller (ultimately, the runtime). This
spec specifies what those values look like, who can construct
them, how they're passed around, and how the package registry
discloses what a qube uses.

## Design goals

1. **No ambient capabilities.** Stdout is `env.out`, not a global.
   The network is `env.net`. Code that doesn't take a capability
   can't use it.
2. **Smallest-capability passing.** A helper that needs the
   network takes `n: Net`, not `env: Env`. The signature
   documents what it touches.
3. **Capabilities are faces.** Per [`faces.md`](./faces.md):
   `Net`, `Fs`, `Audio`, etc. are faces. The runtime provides one
   fit per capability; user code (tests, libraries, sandboxing
   layers) provides others.
4. **Disclosure is mechanical.** The compiler derives the
   capability set from the effect graph
   ([`effects.md`](./effects.md)); the registry surfaces it at
   install. Manifest declarations are cross-checked, not trusted.
5. **Sandboxing is block-scoped.** A `with_capabilities` block
   revokes capabilities for its duration; the call graph inside
   sees them as denied.

## Vocabulary

| Word              | Meaning                                                                              |
|-------------------|--------------------------------------------------------------------------------------|
| **`Env`**         | The top-level capability bundle. A struct with one field per capability category.    |
| **capability**    | A face whose fits perform a category of I/O (Net, Fs, Audio, …).                      |
| **sub-capability**| A field of `Env`; an individual capability value (e.g., `env.net: Net`).             |
| **fit**           | Per `faces.md` — a concrete type fitting a capability face.                          |
| **denial**        | Runtime-enforced revocation via `with_capabilities`.                                  |
| **manifest**      | `qube.json5`'s `capabilities` field — developer-asserted summary.                    |
| **derived set**   | Compiler-computed capability set; emitted into a Wasm custom section.                |

## `Env` and its fields

`Env` is a hierarchical struct. Each field is a capability value
(a fit of the corresponding capability face). The exact fields
shipped by the runtime are:

| Field         | Type            | Provides                                                       |
|---------------|-----------------|----------------------------------------------------------------|
| `env.out`     | `Stdout`        | Write to stdout. `env.out("…")` is sugar for `env.out.write("…\n")`. |
| `env.err`     | `Stderr`        | Write to stderr.                                               |
| `env.exit`    | `ExitFn`        | Terminate the program with an exit code (and optional stderr message). |
| `env.args`    | `[str]`         | Command-line arguments, including argv[0] = program path.       |
| `env.envvars` | `EnvVars`       | Process environment variables. Read-only.                      |
| `env.time`    | `Clock`         | Wall-clock and monotonic time sources.                         |
| `env.random`  | `Rng`           | Cryptographically secure randomness.                           |
| `env.net`     | `Net`           | HTTP, WebSocket, raw sockets. See `q64.net`.                   |
| `env.fs`      | `Fs`            | Filesystem read / write / list / watch. See `q64.fs`.          |
| `env.audio`   | `Audio`         | PCM input/output, audio worklets. See `q64.audio`.             |
| `env.midi`    | `Midi`          | MIDI input/output. See `q64.midi`.                             |
| `env.ai`      | `AiEnv`         | Model loading, inference, vocabularies. See `q64.ai`.          |
| `env.ui`      | `Ui`            | Input events (clicks, keys), frame output. See `q64.ui`.       |

Capabilities not listed above (gfx, video, fs.s3, gpu, …) live
in user qubes or higher-layer stdlib packages — they extend the
capability surface via their own faces and constructors.

`Env` itself is also a face (its fields are field-faces, in
generics.md terminology); a runtime-provided `Env` is one fit.
Test infrastructure provides another (`q64.test.MockEnv`).

### Constructing capabilities — capabilities as faces

Each capability is a face, not a sealed type. Face methods use
the standard `(self, …)` receiver per
[`faces.md` §"Method signatures"](./faces.md):

```q64
pub face Net {
    fn get        (self, url: Url) -> Result<Response, IoError> @io @network
    fn post       (self, url: Url, body: Bytes) -> Result<Response, IoError> @io @network
    fn ws_connect (self, url: Url) -> Result<WebSocket, IoError> @io @network
    // …
}

pub face Fs {
    fn read  (self, path: str)                -> Result<Bytes, IoError> @io @fs
    fn write (self, path: str, data: Bytes)   -> Result<(), IoError>    @io @fs
    // …
}
```

The runtime ships exactly one fit per face (browser → `BrowserNet`;
Wasmtime → `WasmtimeNet`; etc.); the user code never names the
concrete fit. Test code and libraries provide their own fits:

```q64
pub fit MockNet : Net {
    fn get(self, url: Url) -> Result<Response, IoError> {
        Ok(self.lookup(url).unwrap_or(Response.not_found()))
    }
    // …
}

@test
fn test_fetch_users() {
    let n = MockNet.new()
        .on_get(url"https://api.example.com/users", body: r#"[{"name":"Ada"}]"#)
    let users = try fetch_users(n, url"https://api.example.com/users")
    assert(users.len() == 1)
}
```

User libraries also fit capability faces to add adapters
(`fit S3Fs : Fs`, `fit OscMidi : Midi`).

### Sub-capabilities are values

Because capability fields are values (whose types fit the
corresponding face), they can be assigned, named, passed
individually:

```q64
let n: Net = env.net
let users = try fetch_users(n, url"…")

let (logs, audio) = (env.fs, env.audio)        // pair them up
let track = try logs.read("track.q")
try audio.write(generate(track))
```

The smallest-capability passing convention (§Passing) builds on
this: helpers take the field type they need.

## `main` signature

`main` may be declared two ways. Both are valid; the runtime
dispatches on the return type.

### Form 1 — falls off the end (`panic`-on-error)

```q64
fn main(env: Env) {
    let path = env.args[1]
    let content = match env.fs.read(path) {
        Ok(b)  -> b,
        Err(e) -> panic e,
    }
    env.out(content)
}
```

- Falling off the end = exit 0.
- `env.exit(N, msg?)` terminates with code N (and optional
  stderr message).
- Form 1 has no `Result` return type, so `try` propagation is
  unavailable (`TYP300`). Recoverable errors are turned into
  panics with the `match … panic e` shape above when the
  application's policy is "any error is fatal." Errors fitting
  `Error` also fit `Panic` (auto-derive bridge from
  [`errors.md`](./errors.md)), so the runtime's exit-code
  mapping in [`q64-cli.md`](./q64-cli.md) still applies.

### Form 2 — returns `Result`

```q64
fn main(env: Env) -> Result<(), Error> {
    let path = env.args[1]
    let content = try env.fs.read(path)        // ← `try` propagates Err
    env.out(content)
    Ok(())
}
```

- `Ok(())` = exit 0.
- `Err(e)` = exit `e.exit_code` (per `errors.md`'s `Error` face;
  default 1 if not specified).
- `try` propagates `Err` to the return; no panic.
- `env.exit(N)` still works for explicit overrides.

The two forms exist for different cost contracts. Form 1 is the
"crash on first error" CLI shape — verbose at each fallible call
site but ergonomic at the top level where panic-equals-exit is
the natural policy. Form 2 keeps error propagation explicit
through `try` and derives the exit code from the error type;
preferred for any application that wants to distinguish error
kinds cleanly.

Falling off the end is `ENV050` ("`main` returns a value but
ends without explicit return") in Form 2.

## Passing convention: smallest sub-capability

Helpers take the smallest sub-capability they need. A function
that does HTTP takes `n: Net`, not `env: Env`:

```q64
pub fn fetch_users(n: Net, url: Url) -> Result<[User], Error> {
    n.get(url).json<[User]>()
}

pub fn write_config<F: Fs>(f: F, path: str, cfg: Config) -> Result<(), IoError> {
    f.write(path, cfg.serialize())
}
```

`fn fetch_users(n: Net, …)` is shorthand for
`fn fetch_users<N: Net>(n: N, …)` per
[`generics.md`](./generics.md): face-typed parameters auto-
generalize. The compiler dispatches the calls statically.

`q64 fmt --lint` issues `ENV010` when a function takes
`env: Env` but uses only one or two sub-capabilities:

```q64
fn fetch_users(env: Env, url: Url) -> Result<[User], Error> {
//             ^^^^^^^^^ ENV010: over-broad capability parameter; uses only `env.net`
    env.net.get(url).json<[User]>()
}
```

`ENV010` is suppressible with `@allow(ENV010)`. Take `env: Env`
when you genuinely need multiple sub-capabilities and the
combinatorics make face bounds noisier than the alternative.

### Top-level helpers vs library functions

The convention applies most strongly at library boundaries:
exported library functions name their capabilities precisely
because callers need to know what they require. Application code
in `main`-adjacent scopes may take `env: Env` freely; the lint
recognizes "called only from `main` or directly from a `main`-
called scope" as exempt (`ENV011` suppressed).

## Sandboxing: `with_capabilities { … }`

A `with_capabilities` block dynamically revokes the named
capabilities for the duration of its body. Calls into the
revoked capabilities unwind with `panic RuntimeDenied { code:
"ENV030", detail: … }` at the point of use:

```q64
fn run_plugin(env: Env, plugin: PluginFn) {
    with_capabilities(deny: [Net, Fs]) {
        plugin(env)                              // plugin still has env, but
                                                 // net + fs calls panic RuntimeDenied
    }
    // capabilities restored here
}
```

Syntax: `with_capabilities(deny: [<face>, …]) { <body> }`. The
list names capability faces; calls on any value fitting one of
those faces, inside the block (transitively), unwind with
`panic RuntimeDenied { code: "ENV030", … }`. `RuntimeDenied` is
the auto-prelude `Panic`-fitting payload from
[`errors.md`](./errors.md).

### Semantics

- Implemented as a thread-local "denied set." Each capability
  method checks the set on entry and panics `RuntimeDenied` if
  its face is in the set.
- The block restores the previous denied set on exit (LIFO).
- Nested `with_capabilities` blocks compose by union: inner
  block's denials are added to the outer's.
- The denial is **runtime-enforced**, not type-level. A function
  receiving `n: Net` inside a `deny: [Net]` block has a valid
  `Net` value; the value's methods unwind at call time.

### Why runtime, not type-level

A pure type-level denial would require parametrizing every
function over its denial set, which propagates virally through
signatures. The runtime mechanism is the pragmatic compromise:
sandboxing is rare; the language-level cost should fall on the
sandboxer, not on every function in the call graph.

### Auditability

`q64 show denials <fn>` prints the call sites where
`with_capabilities` is used, and the static "this function
called inside a denial block could panic RuntimeDenied" analysis
flows through. Sandboxing isn't invisible — it's just not in the
type.

### Cancellation interaction

A capability denial unwinds via `panic RuntimeDenied`; it
propagates per [`concurrency.md`](./concurrency.md) §"Panics
across tasks". Plugins that may legitimately attempt denied
calls should be spawned in a scope with a typed
`catch (e: RuntimeDenied) { … }` (or the catch-all `catch (e:
Panic) { … }`) block.

## Capability disclosure

Two records of "what does this qube use" exist:

1. **The manifest declaration** in `qube.json5`:

    ```json5
    {
      name: "my-app",
      capabilities: ["Net", "Fs"],
    }
    ```

   Developer-asserted. Human-readable. Subject to drift.

2. **The compiler-derived set**, computed from the effect graph
   (per [`effects.md`](./effects.md)) and emitted into a Wasm
   custom section (`q64.capabilities`). Each effect maps to a
   capability:

    | Effect       | Implies capability |
    |--------------|--------------------|
    | `@network`   | `Net`              |
    | `@fs`        | `Fs`               |
    | `@audio`     | `Audio`            |
    | `@midi`      | `Midi`             |
    | `@ui`        | `Ui`               |
    | `@inference` | `AiEnv`            |
    | `@time`      | `Clock`            |
    | `@random`    | `Rng`              |
    | `@stdio`     | `Stdout` + `Stderr` |

   Compiler-verified. Always accurate.

### `qube publish` cross-check

The two must match. `qube publish` runs the cross-check; mismatch
is `ENV040`:

```
$ qube publish
ERR ENV040: capability mismatch — manifest claims [Net, Fs]
            but compiler derived [Net, Fs, Audio]

  Audio appears via:
    src/notify.q:42  → q64.audio.beep()
    src/notify.q:53  → q64.audio.beep()

  Fix:
    qube.json5:  capabilities: ["Net", "Fs", "Audio"]
    or remove the audio call sites and rebuild.
```

The error block names the call sites that introduced each
unmanifested capability, so the developer can decide whether to
declare it or remove the dependency.

### Registry surfacing

The continuum registry (per
[`continuum-api.md`](./continuum-api.md)) reads both the manifest
field and the Wasm custom section. The qube's page shows:

```
capabilities (manifest + verified):
  Net    ✓ verified — 47 call sites
  Fs     ✓ verified — 12 call sites
  Audio  ✓ verified —  3 call sites
```

`qube add somepackage` lists the capabilities transitively
required and pauses for confirmation when the dependency adds a
capability the parent qube hasn't already declared.

## Capabilities and effects

Every capability method carries the corresponding effect (per
[`effects.md`](./effects.md)):

```q64
pub face Net {
    fn get  (self, url: Url)               -> Result<Response, IoError> @io @network
    fn post (self, url: Url, body: Bytes)  -> Result<Response, IoError> @io @network
    // …
}
```

The effect markers are what the compiler walks for the derived
set. Effect propagation rules (transitive closure across calls,
opaque user effects, `@send` derivation) are specified in
`effects.md` and apply unchanged to capability methods.

### `@realtime` and capabilities

A `@realtime` function cannot call most capability methods —
they allocate, suspend, or block, all forbidden in `@realtime`.
Exceptions are the explicitly real-time-safe operations:

- `env.time.monotonic_ns()` (one Wasm call; no alloc, no suspend).
- `env.random.fill_bytes(buf)` where `buf` is preallocated.
- `env.audio.write_pcm(buf)` when `buf` is owned by the audio
  worklet's pool.

Other capability operations called from `@realtime` are caught
via the `EFF111` ("callee effect outside caller's set") path
from `effects.md`.

## Diagnostic codes

All env diagnostics use the `ENV` prefix. Numbers stable, never
reused. `ENV060`-`ENV099` reserved for expansion.

| Code     | Short message                                  | When                                                                              |
|----------|------------------------------------------------|-----------------------------------------------------------------------------------|
| `ENV010` | over-broad capability parameter (lint)         | Function takes `env: Env` but uses only one or two sub-capabilities.              |
| `ENV011` | (reserved) ENV010 exemption probe              | `q64 fmt --lint` reserves this for "exempted because called only from main."     |
| `ENV020` | `.mock()` outside `@test` context              | A capability fit's mock constructor was called from non-test code.                |
| `ENV030` | capability denied (runtime)                    | A capability call entered a `with_capabilities(deny: …)` block's denial set.       |
| `ENV040` | manifest / derived capability mismatch         | `qube publish` cross-check failed; manifest and compiler-derived sets differ.     |
| `ENV041` | manifest declares unused capability            | `qube publish` warning; manifest lists a capability the code doesn't reach.       |
| `ENV050` | `main` Form 2 ends without return              | `fn main(env: Env) -> Result<…>` body falls off without an explicit `return` / tail expression. |
| `ENV051` | `main` not declared                            | A qube of kind `app` has no `main` function.                                       |
| `ENV052` | `main` signature mismatch                      | `main` exists but doesn't match Form 1 or Form 2.                                  |
| `ENV053` | `with_capabilities` outside any scope           | The block requires a stack frame for the LIFO restoration.                         |
| `ENV054` | `with_capabilities` body uses non-blocking guard | Audio-worklet `@realtime` body cannot enter a `with_capabilities` block (the runtime guard would allocate). |

Codes emitted via the envelope from
[`diagnostics.md`](./diagnostics.md).

## Examples

### Hello world

```q64
fn main(env: Env) {
    env.out("Hello, world!")
}
```

### CLI with args and exit codes (Form 1)

```q64
fn main(env: Env) {
    if env.args.len() < 2 {
        env.exit(2, "usage: cat <file>")
    }
    let path = env.args[1]
    let content = match env.fs.read(path) {
        Ok(b)  -> b,
        Err(e) -> panic e,
    }
    env.out(content)
}
```

An uncaught panic from a Form 1 `main` → exit code 1 (or the
payload's `exit_code` when the payload also fits `Error`, per
`q64-cli.md`).

### CLI with Result propagation (Form 2)

```q64
fn main(env: Env) -> Result<(), Error> {
    let path = try env.args.get(1)
        .ok_or(Error.usage(code: 2, msg: "usage: cat <file>"))
    let content = try env.fs.read(path)
    env.out(content)
    Ok(())
}
```

`Err(e)` returned from `main` → exit code `e.exit_code` (default 1).

### Library function with smallest-capability passing

```q64
pub fn fetch_user(n: Net, id: UserId) -> Result<User, Error> {
    let resp = try n.get(url"https://api.q64.dev/users/{id}")
    resp.json<User>()
}

fn main(env: Env) -> Result<(), Error> {
    let user = try fetch_user(env.net, UserId.from(42))
    env.out("got user: {user.name}")
    Ok(())
}
```

### Test with a mocked capability

```q64
@test
fn test_fetch_user() -> Result<(), Error> {
    let n = MockNet.new()
        .on_get(url"https://api.q64.dev/users/42",
                body: r#"{"id":42,"name":"Ada"}"#)
    let u = try fetch_user(n, UserId.from(42))
    assert(u.name == "Ada")
    Ok(())
}
```

`MockNet` (from `q64.test.capabilities`) fits the `Net` face. The
production `fetch_user` doesn't know or care.

### Sandboxing a plugin

```q64
fn run_user_plugin(env: Env, plugin: PluginFn) -> Result<(), Error> {
    scope {
        with_capabilities(deny: [Net, Fs]) {
            plugin(env)                          // plugin can't escape
        }
    } catch (e: RuntimeDenied) {
        log.warn("plugin attempted denied capability: {e.code} — {e.detail}")
        return Err(Error.plugin_denied(e.detail))
    }
    Ok(())
}
```

### Disclosure walkthrough

```q64
// src/main.q
fn main(env: Env) -> Result<(), Error> {
    let body = try env.net.get(url"https://example.com").body()  // @network
    try env.fs.write("body.txt", body)                            // @fs
    env.out("done")                                                // @stdio
    Ok(())
}
```

```json5
// qube.json5
{
  name: "fetcher",
  capabilities: ["Net", "Fs"],     // ← missing Stdout
}
```

```
$ qube publish
ERR ENV040: capability mismatch — manifest [Net, Fs] vs derived [Net, Fs, Stdout]

  Stdout appears via:
    src/main.q:5  → env.out("done")

  Fix: add "Stdout" to capabilities, or remove the env.out call.
```

After fixing:

```json5
{
  capabilities: ["Net", "Fs", "Stdout"],
}
```

```
$ qube publish
OK fetcher@0.1.0 — capabilities verified [Net, Fs, Stdout]
```

## Open items deferred

- **First-class capability composition operators.** Today
  multiple-capability parameters are spelled `<C: Net + Fs>`;
  sugar like `cn: Net & Fs` deferred.
- **Stronger denial: type-level capability sets.** v0 uses
  runtime denial (`ENV030`). A future version may parametrize
  functions over a denial set for compile-time enforcement;
  requires a redesign of face bounds and is out of scope for v0.
- **Capability versioning.** A qube depending on `Net@1` vs
  `Net@2`; today `Net` is a single face whose face-evolution
  rules (per `faces.md`) apply. Explicit per-capability versions
  deferred.
- **Network sub-capabilities.** `Net.http` vs `Net.ws` vs
  `Net.raw`. v0 treats `Net` as one face; subdividing may matter
  for finer disclosure later.
- **Cross-qube capability delegation.** Library qubes that need
  a runtime-injected capability without taking it as a parameter
  (e.g., a logging library that uses `env.err` ambient-style).
  v0 says: pass it.

## Related specs

- [`faces.md`](./faces.md) — capabilities are faces; runtime
  provides fits; user code provides others.
- [`effects.md`](./effects.md) — effect markers on capability
  methods; the derivation that produces the disclosed capability
  set.
- [`errors.md`](./errors.md) — `Result<T, E>`, `panic`, the
  `Error` face's `exit_code` field used by `main` Form 2.
- [`generics.md`](./generics.md) — `fn fetch(n: Net, …)` as
  shorthand for `fn fetch<N: Net>(n: N, …)`.
- [`concurrency.md`](./concurrency.md) — `ENV030` raises panic;
  propagation via `scope { … } catch { … }`.
- [`memory.md`](./memory.md) — capabilities are plain values
  (`@send` by default); pass through scopes normally.
- [`qube.json5.md`](./qube.json5.md) — the `capabilities` field
  in the manifest; the `qube publish` cross-check.
- [`continuum-api.md`](./continuum-api.md) — registry surfacing
  of capabilities at install time.
- [`q64-cli.md`](./q64-cli.md) — `q64 show capabilities <qube>`,
  `q64 show denials <fn>`, the exit-code table for `main` Form 1.
- [`modules.md`](./modules.md) — `Env`, `Net`, `Fs`, `Audio`,
  `Midi`, `AiEnv`, `Ui`, `Clock`, `Rng`, `Stdout`, `Stderr`,
  `ExitFn`, `with_capabilities` are auto-prelude.
- [`diagnostics.md`](./diagnostics.md) — envelope format for
  `ENV*` codes.
