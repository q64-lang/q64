# Environment & Capabilities

The capability surface. How a q64 program reaches the outside
world — network, filesystem, audio, time, random, UI — and how
it doesn't reach anything it wasn't given.

q64's I/O model is **ambient and typed**, in the SwiftUI
`@Environment` shape: the runtime hands the program a root `env`
binding; every function inside the program reads from it directly
(`env.out`, `env.fs.read`, …) without declaring `env` as a
parameter; the compiler walks the references and synthesizes an
implicit parameter at each function boundary so the capability
flow remains statically tracked and overridable. Sandboxing,
testing, and capability disclosure all hang off the same single
mechanism: shadow the ambient binding.

> **Status: v0 redesign.** Supersedes the earlier "passed, not
> ambient" model. The diagnostic numbering is preserved where it
> still applies; `ENV010` / `ENV011` (over-broad capability
> parameter) are retired. A follow-up sweep across `errors.md`,
> `concurrency.md`, `streams.md`, `faces.md`, `effects.md`,
> `memory.md`, and `spec/tests/golden/` is required to remove
> the residual `env: Env` parameters from their examples.

## Design goals

1. **Ambient, not threaded.** A function that uses `env.out`
   writes `env.out("…")` and stops. It does not declare an `env`
   parameter; the compiler adds one.
2. **Typed, not global.** The `env` binding has a static type
   (`Env`); each field has a static face (`Net`, `Fs`, …). A
   reference to `env.net` contributes `Net` to the function's
   inferred capability set. Capability disclosure is mechanical
   from the call graph, exactly as before.
3. **Overridable at any node.** A `with_capabilities { … }` block
   shadows the ambient binding for the duration of its body.
   Production code, tests, plugins, and sandboxes all use the
   same mechanism.
4. **No coloring.** Capability use does not require a syntax
   marker at the call site beyond `env.X` itself. Helper
   functions read `env.fs` the same way `main` does. The only
   `pub`-boundary requirement is that the function's inferred
   capability set match its declared effects (`effects.md`) and
   the qube's manifest (`qube.json5.md`).
5. **AI-agent friendly.** `grep 'env\.net\.'` enumerates every
   network call site; `qube audit` prints the full transitive
   capability set per dependency; the registry surfaces the same
   set at install.

## Vocabulary

| Word                     | Meaning                                                                              |
|--------------------------|--------------------------------------------------------------------------------------|
| **`Env`**                | The top-level capability bundle. A struct with one field per capability category.    |
| **ambient env binding**  | The lexically-scoped `env` value visible at every reference site in a call tree.     |
| **capability**           | A face whose fits perform a category of I/O (Net, Fs, Audio, …).                     |
| **sub-capability**       | A field of `Env`; an individual capability value (e.g., `env.net: Net`).             |
| **fit**                  | Per `faces.md` — a concrete type fitting a capability face.                          |
| **implicit env parameter** | The parameter the compiler synthesizes at a function boundary when its body references `env.X`. Not visible in the surface signature. |
| **shadowing**            | A `with_capabilities { … }` block replaces the ambient binding for its sub-tree.    |
| **derived set**          | Compiler-computed capability set; emitted into a Wasm custom section.                |

## How the ambient binding works

A reference to `env` (or any sub-capability path: `env.net`,
`env.fs.read(…)`, …) inside a function body desugars to a
**synthesized implicit parameter**, the same machinery as
[`generics.md` §"Implicit face parameters"](./generics.md) — the
parameter is computed from the body's references, then threaded
at every call site from the enclosing lexical binding.

### Inference rule

For a function body `f`:

1. Collect every `env.X` reference where `X` resolves to a field
   of `Env` or to a sub-path through one.
2. Compute the **minimum face** that covers those references:
   - If the body references only `env.out`, the minimum face is
     `Stdout`.
   - If it references `env.out` and `env.fs.read(…)`, the minimum
     covering shape is `{ out: Stdout, fs: Fs }` — a partial `Env`
     binding with two fields.
   - If it references `env.net`, `env.fs`, and `env.audio`, the
     minimum covering shape is `{ net: Net, fs: Fs, audio: Audio }`.
3. The compiler adds one **synthesized parameter per distinct
   sub-capability** (Net, Fs, Audio, …). The function's surface
   signature is unchanged; the implicit parameters are visible
   only via `q64 show env <fn>` (per
   [`q64-cli.md`](./q64-cli.md)).

The synthesized parameters carry the corresponding effect markers
per [`effects.md`](./effects.md): a `Net` parameter contributes
`@network` to the function's inferred effect set; an `Fs`
parameter contributes `@fs`; etc.

### Threading rule

At each call site `f(…)` where `f` has synthesized capability
parameters, the compiler threads each parameter from the
**lexically nearest binding** of the corresponding sub-capability.
The default binding source is the ambient `env`; a
`with_capabilities { … }` block introduces a new binding for the
duration of its sub-tree.

```q64
pub fn fetch_users(url: Url) -> Result<[User], Error> {
    env.net.get(url).json<[User]>()        // env.net referenced
}
// Surface signature: fetch_users(url: Url) -> Result<[User], Error> @network
// Synthesized:       fetch_users<N: Net>(n: N, url: Url) -> … @network

fn main {                                   // env provided by runtime
    let users = try fetch_users(url"…")
    env.out("found {users.len()} users")
}
```

The synthesis is per-call-site monomorphization, sharing the
binary-size considerations of the explicit form (per
[`faces.md` §"Cost we accept"](./faces.md)).

### Reading vs. naming

| Form                                       | What it does                                                                 |
|--------------------------------------------|------------------------------------------------------------------------------|
| `env.out("…")`                              | Reads the ambient `env`. Synthesizes a `Stdout` parameter for the function. |
| `env.fs.read(path)`                         | Reads the ambient `env`. Synthesizes an `Fs` parameter.                     |
| `let n: Net = env.net`                      | Names the sub-capability as a local. Still synthesizes via `env.net`.       |
| `pub fn helper(n: Net, …)` (explicit form)  | Declares the parameter manually. Caller passes the value at the call site.  |

The explicit form is **still valid** and is the right choice when
a function needs to be parametric over which `Net` it gets — e.g.,
library code that may be handed a mock or a custom adapter without
relying on the lexical `with_capabilities` mechanism. Both forms
coexist; the inferred form is the default for application and
helper code.

## `Env` and its fields

`Env` is a hierarchical struct. Each field is a capability value
(a fit of the corresponding capability face). The exact fields
shipped by the runtime are:

| Field         | Type            | Methods carry  | Provides                                                       |
|---------------|-----------------|----------------|----------------------------------------------------------------|
| `env.out`     | `Stdout`        | `@stdout`      | Write to stdout. `env.out("…")` is sugar for `env.out.write("…\n")`. |
| `env.err`     | `Stderr`        | `@stderr`      | Write to stderr.                                               |
| `env.exit`    | `ExitFn`        | `@exit`        | Terminate the program with an exit code (and optional stderr message). |
| `env.args`    | `[str]`         | (none — pure)  | Command-line arguments, including argv[0] = program path.       |
| `env.envvars` | `EnvVars`       | `@envvars`     | Process environment variables. Read-only.                      |
| `env.time`    | `Clock`         | `@time`        | Wall-clock and monotonic time sources.                         |
| `env.random`  | `Rng`           | `@random`      | Cryptographically secure randomness.                           |
| `env.net`     | `Net`           | `@network`     | HTTP, WebSocket, raw sockets. See `q64.net`.                   |
| `env.fs`      | `Fs`            | `@fs`          | Filesystem read / write / list / watch. See `q64.fs`.          |
| `env.kv`      | `KeyValue`      | `@kv`          | Key-value store: get / set / delete / list / atomics. See `q64.kv`. |
| `env.audio`   | `Audio`         | `@audio`       | PCM input/output, audio worklets. See `q64.audio`.             |
| `env.midi`    | `Midi`          | `@midi`        | MIDI input/output. See `q64.midi`.                             |
| `env.ai`      | `AiEnv`         | `@inference`   | Model loading, inference, vocabularies. See `q64.ai`.          |
| `env.ui`      | `Ui`            | `@ui`          | Input events (clicks, keys), frame output. See `q64.ui`.       |

Capabilities not listed above (gfx, video, fs.s3, gpu, …) live
in user qubes or higher-layer stdlib packages — they extend the
capability surface via their own faces and constructors.

`Env` itself is also a face (its fields are field-faces, in
`generics.md` terminology); the runtime provides one fit. Test
infrastructure provides another (`q64.test.MockEnv`).

### Capabilities as faces

Each capability is a face, not a sealed type. Face methods use
the standard `(self, …)` receiver per
[`faces.md` §"Method signatures"](./faces.md):

```q64
pub face Net {
    fn get        (self, url: Url) -> Result<Response, IoError> @network
    fn post       (self, url: Url, body: Bytes) -> Result<Response, IoError> @network
    fn ws_connect (self, url: Url) -> Result<WebSocket, IoError> @network
}

pub face Fs {
    fn read  (self, path: str)                -> Result<Bytes, IoError> @fs
    fn write (self, path: str, data: Bytes)   -> Result<(), IoError>    @fs
}
```

A key-value store is the same shape. `env.kv` is already an **opened
bucket**: the WASI `store.open(identifier)` step is performed by the host,
which pins the bucket to the qube's identity (on qubepods: `org/project/app`),
so user code never names a namespace and a qube cannot reach another tenant's
keys. Keys are `str`; values are `Bytes`.

```q64
pub face KeyValue {
    fn get       (self, key: str)               -> Result<Option<Bytes>, IoError> @kv
    fn set       (self, key: str, value: Bytes)  -> Result<(), IoError>           @kv
    fn delete    (self, key: str)                -> Result<(), IoError>           @kv
    fn exists    (self, key: str)                -> Result<bool, IoError>         @kv
    fn list      (self, cursor: Option<str>)     -> Result<KvPage, IoError>       @kv
    fn increment (self, key: str, delta: i64)    -> Result<i64, IoError>          @kv
    fn cas       (self, key: str, expected: Option<Bytes>, value: Bytes)
                                                 -> Result<bool, IoError>         @kv
}

pub struct KvPage { keys: [str], cursor: Option<str> }   // cursor None = listing complete
```

Effects compose with `+` per
[`effects.md` §"Effect annotations on functions"](./effects.md);
the implication graph closes capability markers into `@io` as
needed.

### Capability methods and cancellation

Capability-face methods (`Net.get`, `Fs.read`, …) take no `ctx:
Cancel` and do not carry `@cancel`. They may suspend on host
I/O, but the suspension is not observable to the caller's
cancellation channel — a call in progress runs to its host
result. This keeps the simple `try env.net.get(url)` shape free
of ctx threading.

Cancellation-aware variants live one layer up, in the `q64.net.http`
/ `q64.fs.aio` / similar sub-modules:

```q64
// Lives in q64.net.http; the concurrency.md examples use this form.
pub fn get(ctx: Cancel, url: Url)
    -> Result<Response, IoError> @cancel + @network
{
    env.net.get(url)        // ambient env; same runtime fit
}
```

`ctx` is still an explicit parameter — cancellation is a
control-flow concern, not a capability, so it does not ride on
the ambient mechanism. Capabilities are *what you may touch*;
`ctx` is *whether you may continue*.

The runtime ships exactly one fit per face (browser → `BrowserNet`;
Wasmtime → `WasmtimeNet`; etc.); user code never names the
concrete fit. Test code and libraries provide their own fits
through the override mechanism below.

## Env and the Component Model (WASI Preview 3)

When a qube is emitted as a **component** (opt-in; per
[`modules.md` §"The qube as a component"](./modules.md) and
[`README.md` §"Wasm 3.0 is the platform"](./README.md)), each capability
the program uses becomes a **component import** the host supplies. For the
capabilities that have a standard WASI counterpart, the import *is* the
WASI Preview 3 (WASI 0.3) interface — no q64-specific host ABI. The mapping is
a column-extension of the `Env`-fields table above; the same row keys.

### Tracking the WASIp3 release candidate

q64 targets **WASIp3** (WASI 0.3), whose Component Model promotes `stream<T>`
and `future<T>` to native canonical-ABI types and retires the Preview 2
`wasi:io/poll` + `wasi:io/streams` resource ceremony. WASIp3 is at
**release-candidate** status upstream; q64 commits to the RC and **re-pins on
every upstream RC release** until WASI 1.0:

- The compiler and runtime adapters pin to a single WASI snapshot — currently
  **`0.3.0-rc-2026-03-15`**, the snapshot Wasmtime 43 implements. The pin moves
  forward as new RC snapshots land; interface and type names may shift between
  snapshots, and a re-pin may be a breaking change for emitted components until
  WASI 1.0.
- The pinned snapshot is recorded in the emitted component's WIT package
  versions and surfaced by `qube audit`, so a component declares exactly which
  RC it was built against.
- There is **no Preview 2 fallback**. q64 commits fully to WASIp3 — Preview 2
  is not a selectable target. The only frozen ABI floor a consumer gets is the
  pinned RC snapshot itself; until WASI 1.0 there is no long-term-stable WASI
  target, and re-pinning is the mechanism for moving forward. (`preview1`
  remains available for legacy **core-module** hosts that predate the
  Component Model; it carries no component, no native async, and no RPC.)

> **What "0.3" versions, and what stays 0.2.x.** WASIp3's `0.3` is the **async
> `wasi:io`** layer (native `stream<T>`/`future<T>`, retiring the Preview 2
> `poll`/`streams` resource ceremony) plus the component-model async ABI. The
> **`wasi:cli` command world** (`wasi:cli/run`, `wasi:cli/stdout`, …) is *not*
> bumped to 0.3 — it stays **`wasi:cli@0.2.x`** upstream (even the wasi-cli
> `v0.3.0-rc-*` tags declare `package wasi:cli@0.2.7`). So a q64 command
> component correctly imports `wasi:cli/stdout@0.2.x` and exports
> `wasi:cli/run@0.2.x`; "no Preview 2" means q64 does not target the synchronous
> Preview 2 *runtime* — it runs under the async WASIp3 runtime (`wasmtime run -S
> p3`), where the underlying `wasi:io` streams are 0.3. The `wasi:cli` interface
> version is the latest the upstream command world ships, not a separate q64
> choice.
>
> **Implementation status.** Today q64 lowers `env.out` to a `preview1`
> `fd_write` core import and lifts it with `wasm-tools component new --adapt`
> (the vendored adapter), which yields a command using the *synchronous*
> `wasi:io/streams@0.2.x` write — correct as a command but not yet the async
> path. Emitting genuinely async `wasi:io@0.3` I/O (no adapter shortcut) is the
> next codegen milestone; the runtime is already WASIp3 via `-S p3`.

### Env ↔ WASI Preview 3

| `Env` field | Capability face | WASI Preview 3 interface(s) |
|-------------|-----------------|------------------------------|
| `env.out`     | `Stdout`   | `wasi:cli/stdout`                                        |
| `env.err`     | `Stderr`   | `wasi:cli/stderr`                                        |
| `env.exit`    | `ExitFn`   | `wasi:cli/exit`                                          |
| `env.args`    | `[str]`    | `wasi:cli/environment` (`get-arguments`)                |
| `env.envvars` | `EnvVars`  | `wasi:cli/environment` (`get-environment`)              |
| `env.time`    | `Clock`    | `wasi:clocks/{wall-clock, monotonic-clock}` (`sleep` returns `future<()>`) |
| `env.random`  | `Rng`      | `wasi:random/random` (+ `insecure-seed` for non-crypto) |
| `env.net`     | `Net`      | `wasi:sockets/{tcp, udp, instance-network, ip-name-lookup}` + `wasi:http/handler` (outbound HTTP, imported) |
| `env.fs`      | `Fs`       | `wasi:filesystem/{types, preopens}`                     |
| `env.kv`      | `KeyValue` | `wasi:keyvalue/{store, atomics}` (separate WASI proposal — see note) |
| `env.audio`   | `Audio`    | **no WASI equivalent** — host-specific custom WIT       |
| `env.midi`    | `Midi`     | **no WASI equivalent** — host-specific custom WIT       |
| `env.ui`      | `Ui`       | **no WASI equivalent** — host-specific custom WIT       |
| `env.ai`      | `AiEnv`    | **no WASI equivalent** — host-specific custom WIT       |

The WASI version tracks the active target's `wasi` setting
(`targets.<name>.wasmtime.wasi`, default `"preview3"` —
[`qube.json5.md` §Targets](./qube.json5.md)) and the snapshot pin above. The
four capabilities with no WASI interface (`Audio`, `Midi`, `Ui`, `AiEnv`) are
imported through custom WIT defined per runtime adapter (`runtime/<host>/`);
they are q64-ecosystem interfaces, not WASI.

`env.kv` is a third case: it maps to the **`wasi:keyvalue`** proposal
(`store` + `atomics`) — real WASI (unlike the four above), but a separate
WASI-CG package versioned **independently** of the pinned `wasip3` core
snapshot. Its own version pin is recorded in the emitted component and
surfaced by `qube audit`. The `store.open(identifier)` step is the host's,
not the qube's: the runtime hands `env.kv` already bound to a bucket pinned
to the qube's identity, which is how capability-scoped multi-tenancy works
without the qube ever naming a namespace (qubepods pins it to `org/project/app`).

### Face method ↔ WIT function mapping

A capability face becomes a component **import**: the host supplies the fit.
Each face method maps to a WIT function on the corresponding interface, and
the q64 `self` receiver is realized as an adapter-held WASI **resource
handle** (or, for byte I/O under WASIp3, the native `stream<u8>`) that q64
user code never sees:

| q64 face method | WIT function |
|-----------------|--------------|
| `Fs.read(self, path: str) -> Result<Bytes, IoError>`  | `wasi:filesystem/types.descriptor.read` (handle held by the adapter) |
| `Fs.write(self, path: str, data: Bytes) -> Result<(), IoError>` | `wasi:filesystem/types.descriptor.write` |
| `Net.get(self, url: Url) -> Result<Response, IoError>` | `wasi:http/handler.handle` (async; request/response via `wasi:http/types`, bodies as `stream<u8>`) |
| `Stdout.write(self, s: str)`                          | `wasi:cli/stdout.get-stdout` → write to the returned `stream<u8>` |
| `KeyValue.get(self, key: str) -> Result<Option<Bytes>, IoError>` | `wasi:keyvalue/store.bucket.get` (bucket handle held by the adapter) |
| `KeyValue.set(self, key: str, value: Bytes) -> Result<(), IoError>` | `wasi:keyvalue/store.bucket.set` |
| `KeyValue.increment(self, key: str, delta: i64) -> Result<i64, IoError>` | `wasi:keyvalue/atomics.increment` |

Under WASIp3, byte I/O is the native canonical-ABI `stream<u8>`: stdout/stderr
hand back a `stream<u8>` directly, and there is no `wasi:io/streams`
output-stream resource or `wasi:io/poll` pollable to manage (the Preview 2
ceremony is gone).

The mapping direction is fixed: **capability faces are imports** (the world
*needs* them from the host); the qube's own public functions are exports
(§3). WASI **resources** that remain in Preview 3 (e.g. the filesystem
`descriptor`, socket handles) are an adapter-internal concept — they are
deliberately **not** surfaced as q64 faces or fits (which would blur the
[`faces.md`](./faces.md) boundary) and are **not** transmissible over RPC (they
reference instance-local state; see [`rpc.md`](./rpc.md)). `stream<T>` and
`future<T>`, by contrast, are *values* in Preview 3, not resources, so they do
cross the boundary and the wire — that is what carries the
`Signal` / `Event` / `Stream` family ([`streams.md`](./streams.md)). q64 user
code only ever sees the typed face method.

### HTTP service entry point (`wasi:http`)

A qube can serve HTTP by exporting a handler instead of (or alongside) a
`main`. The handler is a normal `pub fn` carrying the **`@http_handler`**
annotation (per [`annotations.md`](./annotations.md)); the name is free:

```q64
@http_handler
pub fn handle(req: Request) -> Response @network {
    Response.ok("Hello, q64.")
}
```

When the qube is emitted as a component, the `@http_handler` function is
exported as `wasi:http/handler` — the unified Preview 3 handler interface,
`handle: async func(request) -> result<response, error-code>`; the manifest
opts in via `component.worlds: ["wasi:http/proxy"]`
([`qube.json5.md` §Component](./qube.json5.md)). The core module just exports an
ordinary function — the component wrapper is what makes it an HTTP handler.

`Request` and `Response` here are **`wasi:http`-shaped types**, mapping to the
Preview 3 `wasi:http/types.request` and `.response` resources. Preview 3
collapses Preview 2's split incoming/outgoing request and response resources
into a single `request` and a single `response` used in both directions, so the
server-side `Request` / `Response` and the client-side `Response` returned by
`Net.get` above share their underlying WIT types. Bodies are `stream<u8>`
(with a trailing `future<result<option<trailers>, error-code>>`). All lower per
the canonical-ABI rules in [`modules.md` §"The qube as a component"](./modules.md).

This is the integration point for **qubepods**, which serves each qube as a
per-qube HTTPS endpoint: a qube built with `component: { emit: true, worlds:
["wasi:http/proxy"] }` is a drop-in endpoint runnable under generic
Component Model HTTP lifting (`wasmtime serve`, componentize-js / jco on
Cloudflare Workers, or wasmCloud) with no qubepods-specific ABI. The same
endpoint doubles as a wRPC server (see [`rpc.md`](./rpc.md)).

### Channel entry point (`@channel_handler`)

A qube can serve a **long-lived bidirectional stream** instead of a run-once
`main` or a request/response `handle`. A `pub fn` carrying **`@channel_handler`**
(per [`annotations.md`](./annotations.md)) receives a remote `Channel<Tx, Rx>`
([`rpc.md` §"Remote channels"](./rpc.md)) as its session: it reads inbound
messages and sends outbound ones until either side closes. The name is free.

The motivating case is an **agent**: a text stream between a user (the frontend
qube) and an agent (the backend qube). `Tx` is what the agent sends (assistant
text); `Rx` is what it receives (user text):

```q64
// Backend agent qube, deployed to qubepods; rpc.export: true.
@channel_handler
pub fn chat(session: Channel<str, str>) @wire + @inference {
    for user_line in session {                       // inbound user text (Rx)
        let toks = env.ai.complete(user_line)        // Stream<str> of model tokens
        for_each(toks) |tok| { session.send(tok) }   // stream the reply back (Tx)
    }                                                // loop ends when the user closes
}
```

```q64
// Frontend qube (browser); rpc.import = { "agent": "wrpc://…qubepods.app" }.
// It holds the dual end — Channel<str, str>: send user text, receive agent text.
fn main -> Result<(), Error> @wire {
    let agent = connect<agent.chat>()                // over WebTransport
    spawn {
        for tok in agent { env.ui.append(tok) }      // render streamed agent text
    }
    for line in env.ui.lines() {
        agent.send(line)                             // send each user line
    }
    Ok(())
}
```

When emitted as a component, the `@channel_handler` export lowers to a wRPC
world whose signature is the paired `stream<Tx>` / `stream<Rx>`
([`rpc.md` §"Remote channels"](./rpc.md)); on qubepods it is served at the same
per-qube endpoint as `wasi:http`, so one deployed agent qube is reachable as an
HTTP page **and** a streaming channel. Browser↔qubepods rides WebTransport; the
frontend never manages sockets. The `@inference` on `chat` is the same
`env.ai` capability disclosed everywhere else — the agent's model use shows up
in its derived capability set.

**Generative UI.** The streamed messages need not be plain text — the agent can
emit **HTML on the fly** (the channel's `Tx` is just markup, or later a typed
UI-update message), and the client renders each update live. Because that HTML
is model-generated, and therefore untrusted, the client renders it in a
**sandboxed surface** — a no-`allow-scripts` iframe — so the agent can paint the
UI (a form to capture input, a table of `env.kv` values, a chart) without being
able to run script in the user's page. The trust boundary is the renderer, not
the source: static asset, stateless qube, and live agent all go through the same
sandbox. On qubepods this is already concrete — the per-project test page
renders a backend's HTML response in exactly such an iframe, so a qube (or a
streaming agent) paints its own UI while the host stays in control.

## Wire ABI: `fs.read` (v0)

The first hand-specced capability wire ABI beyond `env.out` (decision
recorded in [`faces.md`](./faces.md) §"Host ABI for capability
faces"). The v0 surface is `env.fs.read(path: str) ->
Result<str, i64>` — `Ok(contents)` with the file's bytes as a `str`,
or `Err(code)` (1 unopenable, 2 doesn't fit in growable memory), so
`try env.fs.read(path)` propagates. (`IoError`/`Bytes` refine the
types when those land.) Marks the function `@fs`; the WIT lift
imports `wasi:filesystem/*`.

Import: `env.fs_read : (dest, path_ptr, path_len) -> i64`, all three
parameters address-width (i32 on wasm32, i64 on wasm64).

1. The guest passes `dest` = the current arena pointer; the host reads
   the UTF-8 path from `[path_ptr, path_ptr+path_len)`, opens the file
   (relative paths resolve against the host's working directory),
   **grows the guest memory if needed**, writes the contents at
   `dest`, and returns the byte length.
2. A negative return means failure; the guest boxes `Err(-len)`.
3. On success the guest bumps `sp` past the contents and boxes
   `Ok((dest, len))` — a `Result<str, i64>` value.

The v0 host grants `@fs` unconditionally; the runtime-denial story
(ENV030, `with_capabilities`) gates it later.

## `main` signature

`main` may be declared two ways. Both are valid; the runtime
dispatches on the return type.

### Form 1 — falls off the end (`panic`-on-error)

```q64
fn main {
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
- No `Result` return type, so `try` propagation is unavailable
  (`TYP300`). Recoverable errors turn into panics via
  `match … panic e` when the application's policy is "any error
  is fatal." Errors fitting `Error` also fit `Panic` (auto-derive
  bridge from [`errors.md`](./errors.md)), so the runtime's
  exit-code mapping in [`q64-cli.md`](./q64-cli.md) still applies.

### Form 2 — returns `Result`

```q64
fn main -> Result<(), Error> {
    let path = env.args[1]
    let content = try env.fs.read(path)
    env.out(content)
    Ok(())
}
```

- `Ok(())` = exit 0.
- `Err(e)` = exit `e.exit_code` (per `errors.md`'s `Error` face;
  default 1 if not specified).
- `try` propagates `Err` to the return; no panic.
- `env.exit(N)` still works for explicit overrides.

### Explicit-env forms (still valid)

```q64
fn main(env: Env) { … }
fn main(env: Env) -> Result<(), Error> { … }
```

Naming `env` explicitly is permitted for visibility — useful when
documenting the entry point, for tests that want to receive a
prepared `MockEnv` directly, or in library code that publishes a
`main`-like helper. The body is identical to the implicit forms;
inside, `env` resolves to the parameter rather than the runtime-
provided binding.

`ENV050` ("`main` Form 2 ends without explicit return") and
`ENV052` ("`main` signature mismatch") apply unchanged. `ENV051`
("`main` not declared") now permits any of the four forms above.

## Overriding the ambient binding — `with_capabilities { … }`

A `with_capabilities` block shadows the ambient `env` binding for
the duration of its body. Two override flavors, composable:

```q64
with_capabilities(deny: [Net, Fs]) {
    plugin()                             // env.net / env.fs panic RuntimeDenied
}

with_capabilities(use: { net: MockNet.new() }) {
    fetch_users(url"…")                  // env.net resolves to MockNet
}

with_capabilities(
    use:  { net: MockNet.new() },
    deny: [Fs],
) {
    integration_test()                   // mocked net, denied fs
}
```

Syntax:

```
WithCapsStmt := "with_capabilities" "(" CapsOverrides ")" Block
CapsOverrides
            := ("use" ":" "{" CapField ("," CapField)* ","? "}")?
               ("," "deny" ":" "[" FaceRef ("," FaceRef)* ","? "]")?
CapField    := IDENT ":" Expr        (* e.g., net: MockNet.new() *)
```

`use:` provides a value for one or more `Env` fields; the new
binding is in scope inside the block. `deny:` lists faces whose
calls must unwind with `panic RuntimeDenied`. Both arguments are
optional; at least one must be present.

### Semantics

- **`use:`** introduces a fresh `env` binding inside the block.
  The new binding has the listed fields replaced; unlisted fields
  inherit from the enclosing binding. The compiler resolves the
  inferred capability parameters of every call inside the block
  to the new binding.
- **`deny:`** is a runtime denial set (per the earlier spec).
  Capability methods check the set on entry and panic
  `RuntimeDenied` if their face is listed. The denied set
  composes with the enclosing one by union; nested blocks
  accumulate denials.
- The block restores the previous binding on exit (LIFO).
- **`use:` substitutions are compile-time-resolved**; the
  compiler statically routes references to the new binding.
  **`deny:` is runtime-enforced**; a value passed out of the
  block (e.g., into a returned closure) carries the denial in
  its captured environment.

### Why two override mechanisms

`use:` is the testing / mocking story — replace one capability
with a controlled fit. `deny:` is the sandboxing story — strip a
capability for a sub-tree, even if the code inside believes it
has one. They compose: a sandbox can both deny `Fs` and supply
a mock `Net`.

Cancellation interaction is unchanged: a `RuntimeDenied` panic
propagates per [`concurrency.md`](./concurrency.md) §"Panics
across tasks"; intercept it with a typed
`catch (e: RuntimeDenied) { … }` arm.

## Inferred capability set — what `pub` exposes

A function's capability set is the union of:

1. Synthesized parameters from `env.X` references in its body.
2. Explicit face-typed parameters in its signature (e.g., `n: Net`).
3. Transitive contributions from callees' sets.

For a `pub` function, the inferred set is part of the qube's
public surface. The compiler emits the set into the function's
effect signature and (per `effects.md`) verifies it matches any
explicit effect annotation. The qube manifest's `capabilities`
field is generated from the union of all `pub` items' sets at
`qube publish` time (synced in place — see §"`qube publish` sync";
`ENV040` is the registry-side backstop).

The inferred set is computed **after** `with_capabilities`
resolution: a function whose body wraps every call in
`with_capabilities(deny: [Net, Fs]) { … }` does **not** contribute
those capabilities to its inferred set if the denial fully covers
the call paths. (In practice, denials are leaves of a call tree;
this rule matters mostly for sandboxing plugins.)

`q64 show env <fn>` prints:

- The synthesized capability parameters for the function.
- Their contribution to the effect set.
- Per call site, which ambient binding the parameter routes to.

## Testing with mocks

The mock pattern is the `use:` override:

```q64
pub fit MockNet : Net {
    fn get(self, url: Url) -> Result<Response, IoError> {
        Ok(self.lookup(url).unwrap_or(Response.not_found()))
    }
    // …
}

@test
fn test_fetch_users() {
    with_capabilities(use: { net: MockNet.new()
        .on_get(url"https://api.example.com/users",
                body: r#"[{"name":"Ada"}]"#) }) {
        let users = try fetch_users(url"https://api.example.com/users")
        assert(users.len() == 1)
    }
}
```

The production `fetch_users` reads `env.net` ambiently; the test
shadows the binding; the test's `MockNet` is the value the
synthesized parameter resolves to. No alternative entry point,
no dependency-injection framework.

For library code that wants to be parametric over `Net` without
relying on the ambient mechanism (e.g., because it needs to fork
into two parallel `Net` values in one call), the explicit form
is still available:

```q64
pub fn race(a: Net, b: Net, url: Url) -> Response { … }
```

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
   custom section (`q64.capabilities`). Each core capability
   effect maps to a capability face per the table below.
   Compiler-verified. Always accurate.

| Effect       | Implies capability  |
|--------------|---------------------|
| `@network`   | `Net`               |
| `@fs`        | `Fs`                |
| `@kv`        | `KeyValue`          |
| `@audio`     | `Audio`             |
| `@midi`      | `Midi`              |
| `@ui`        | `Ui`                |
| `@inference` | `AiEnv`             |
| `@time`      | `Clock`             |
| `@random`    | `Rng`               |
| `@stdout`    | `Stdout`            |
| `@stderr`    | `Stderr`            |
| `@exit`      | `ExitFn`            |
| `@envvars`   | `EnvVars`           |

`@io` is the umbrella; finer-grained capability effects imply it.
The mapping is 1:1 from effect marker to capability face. Every
capability is reachable through an effect marker on the relevant
`Env`-field method; no side-channel from call-site reachability.

The one capability effect with **no** `Env` field is `@wire` (per
[`effects.md`](./effects.md) and [`rpc.md`](./rpc.md)): it is not an
ambient `env.X` capability but arises from calling an *imported remote
qube's* function. It still discloses like the others — it appears in the
derived set, in `qube audit`, and in the component's import list — but its
"capability" is an imported remote `world`, not an `Env` field.

### `qube publish` sync

The manifest's `capabilities` field is **generated** (per
[`qube.json5.md`](./qube.json5.md) §Capabilities): `qube publish`
derives the set from the compiler and rewrites the field in place
before packing, reporting the change:

```
$ qube publish
qube publish: capabilities synced to ["Audio", "Fs", "Net"] (compiler-derived)
```

There is nothing for the developer to fix by hand — the field
follows the code. The decision a publisher actually makes is
whether the *derived* set is the one they intend to ship;
`q64 show capabilities` names the call sites that introduce each
capability, so an unexpected entry (say, `Audio` pulled in by a
new dependency) can be traced and removed at the source.

`ENV040` (missing capability) and `ENV041` (extraneous capability)
remain the **registry-side backstop**: the server re-derives the
set from the uploaded archive and rejects a manifest that
disagrees. Because the toolchain syncs before upload, these fire
only for stale or non-toolchain clients.

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
[`effects.md`](./effects.md)). The effect markers are what the
compiler walks for the derived set. Effect propagation rules
(transitive closure across calls, opaque user effects, `@send`
derivation) are specified in `effects.md` and apply unchanged to
both ambient-referenced and explicitly-passed capability values.

The same derived set is what becomes a **component's import list** when a
qube is emitted as a component: each capability effect maps to the WASI (or
host-specific) WIT interface it imports. q64's compile-time capability proof
*is* the host-visible import surface — the synthesis rule and the full
effect→WIT-import table are specified in
[`effects.md` §"Effects and the Component Model"](./effects.md), which is
authoritative; this file is the home of the WASI-interface specifics above.

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
reused. `ENV010` / `ENV011` (over-broad capability parameter) are
**retired** by this revision — the ambient model removes the
parameter-shape concern they policed. `ENV060`–`ENV099` reserved
for expansion.

| Code     | Short message                                  | When                                                                              |
|----------|------------------------------------------------|-----------------------------------------------------------------------------------|
| `ENV010` | (retired)                                      | Replaced by ambient capability model. Number reserved; not reused.                |
| `ENV011` | (retired)                                      | Companion to ENV010. Number reserved; not reused.                                 |
| `ENV020` | `.mock()` outside `@test` context              | A capability fit's mock constructor was called from non-test code.                |
| `ENV030` | capability denied (runtime)                    | A capability call entered a `with_capabilities(deny: …)` block's denial set.       |
| `ENV040` | manifest / derived capability mismatch         | Registry backstop at publish: the uploaded manifest omits a capability the server's effect index detects. A toolchain `qube publish` syncs first, so this indicates a stale or non-toolchain client. |
| `ENV041` | manifest declares unused capability            | Registry backstop at publish (warning): the uploaded manifest lists a capability the code doesn't reach. |
| `ENV050` | `main` Form 2 ends without return              | `fn main -> Result<…>` (or `fn main(env: Env) -> Result<…>`) body falls off without an explicit `return` / tail expression. |
| `ENV051` | `main` not declared                            | A qube of kind `app` has no `main` function.                                       |
| `ENV052` | `main` signature mismatch                      | `main` exists but doesn't match any of the four permitted shapes.                 |
| `ENV053` | `with_capabilities` outside any scope          | The block requires a stack frame for the LIFO restoration.                         |
| `ENV054` | `with_capabilities` body uses non-blocking guard | Audio-worklet `@realtime` body cannot enter a `with_capabilities` block (the runtime guard would allocate). |
| `ENV055` | `with_capabilities(use:)` field not on `Env`   | A field name in the `use:` map does not correspond to an `Env` field.             |
| `ENV056` | `env` reference from `@pure` function          | A `@pure` function references `env.X`; ambient capability use is incompatible with `@pure`. |

Codes emitted via the envelope from
[`diagnostics.md`](./diagnostics.md).

## Examples

### Hello world

```q64
fn main {
    env.out("Hello, world!")
}
```

### CLI with args and exit codes (Form 1)

```q64
fn main {
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
fn main -> Result<(), Error> {
    let path = try env.args.get(1)
        .ok_or(Error.usage(code: 2, msg: "usage: cat <file>"))
    let content = try env.fs.read(path)
    env.out(content)
    Ok(())
}
```

`Err(e)` returned from `main` → exit code `e.exit_code` (default 1).

### Library function that uses the network ambiently

```q64
pub fn fetch_user(id: UserId) -> Result<User, Error> {
    let resp = try env.net.get(url"https://api.q64.dev/users/{id}")
    let user = try resp.json<User>()
    Ok(user)
}

fn main -> Result<(), Error> {
    let user = try fetch_user(UserId.from(42))
    env.out("got user: {user.name}")
    Ok(())
}
```

The compiler walks `fetch_user`'s body, finds `env.net`,
synthesizes a `Net` parameter, attaches `@network` to the
effect signature. At the call site in `main`, the runtime-
provided `env.net` flows through automatically.

### Test with a mocked capability

```q64
@test
fn test_fetch_user() -> Result<(), Error> {
    with_capabilities(use: {
        net: MockNet.new()
            .on_get(url"https://api.q64.dev/users/42",
                    body: r#"{"id":42,"name":"Ada"}"#)
    }) {
        let u = try fetch_user(UserId.from(42))
        assert(u.name == "Ada")
        Ok(())
    }
}
```

`MockNet` (from `q64.test.capabilities`) fits the `Net` face.
Inside the `with_capabilities` block, `env.net` resolves to the
mock; `fetch_user`'s synthesized parameter receives it; the
production code path doesn't know it's running against a mock.

### Sandboxing a plugin

```q64
pub type PluginFn = fn

fn run_user_plugin(plugin: PluginFn) -> Result<(), Error> {
    scope {
        with_capabilities(deny: [Net, Fs]) {
            plugin()                          // plugin can't escape
        }
    } catch (e: RuntimeDenied) {
        env.err.write("plugin attempted denied capability: {e.code} — {e.detail}")
        return Err(Error.plugin_denied(e.detail))
    }
    Ok(())
}
```

`PluginFn` is a parameterless function type; the plugin reads
the ambient `env` (now shadowed by the `deny: …` block) just
like any other function.

### Explicit form for parametric library code

```q64
pub fn race(a: Net, b: Net, url: Url) -> Response {
    scope {
        let h1 = spawn { a.get(url) }
        let h2 = spawn { b.get(url) }
        select {
            r = h1.await() -> r,
            r = h2.await() -> r,
        }
    }
}
```

`race` is genuinely parametric over two `Net` values — the
ambient mechanism can't supply them both. The explicit form
remains the right tool; it's just no longer the default for
single-capability use.

### Disclosure walkthrough

```q64
// src/main.q
fn main -> Result<(), Error> {
    let body = try env.net.get(url"https://example.com").body()
    try env.fs.write("body.txt", body)
    env.out("done")
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

- **`@TaskLocal`-style user-defined ambients.** The ambient
  mechanism currently special-cases `env`. Whether to expose the
  same machinery for user code (`@ambient struct Logger { … }`)
  is open; the registry's capability disclosure model would need
  to grow alongside.
- **Async-task env capture rules.** `spawn { … }` currently
  captures the lexical env, including any `with_capabilities`
  overrides in scope. Cross-thread tasks need `@send` on the
  captured env's substituted fields. The exact compositional
  rule (does `spawn` clone the binding, or share via a
  cross-thread handle?) is deferred until the runtime adapter
  spec lands.
- **First-class capability composition operators.** Today
  multiple-capability parameters in the explicit form are spelled
  `<C: Net + Fs>`; sugar like `cn: Net & Fs` deferred.
- **Stronger denial: type-level capability sets.** v0 uses
  runtime denial (`ENV030`). A future version may parametrize
  functions over a denial set for compile-time enforcement;
  requires a redesign of face bounds and is out of scope for v0.
- **Capability versioning.** A qube depending on `Net@1` vs
  `Net@2`; today `Net` is a single face whose face-evolution
  rules (per `faces.md`) apply.
- **Network sub-capabilities.** `Net.http` vs `Net.ws` vs
  `Net.raw`. v0 treats `Net` as one face.

## Related specs

- [`faces.md`](./faces.md) — capabilities are faces; runtime
  provides fits; user code provides others.
- [`generics.md`](./generics.md) — `env`-reference synthesis
  shares machinery with §"Implicit face parameters"; the inferred
  parameter is monomorphized per call site like any other.
- [`effects.md`](./effects.md) — effect markers on capability
  methods; the derivation that produces the disclosed capability
  set.
- [`errors.md`](./errors.md) — `Result<T, E>`, `panic`, the
  `Error` face's `exit_code()` method used by `main` Form 2.
- [`concurrency.md`](./concurrency.md) — `ENV030` raises panic;
  propagation via `scope { … } catch { … }`. `with_capabilities`
  composes with `scope`'s LIFO unwind.
- [`memory.md`](./memory.md) — capabilities are plain values
  (`@send` by default); pass through scopes normally. The ambient
  binding lives in the enclosing function's scope arena.
- [`qube.json5.md`](./qube.json5.md) — the `capabilities` field
  in the manifest; the `qube publish` sync.
- [`continuum-api.md`](./continuum-api.md) — registry surfacing
  of capabilities at install time.
- [`q64-cli.md`](./q64-cli.md) — `q64 show env <fn>` (new) prints
  the synthesized capability parameters; `q64 show capabilities
  <qube>`, `q64 show denials <fn>`, the exit-code table for
  `main` Form 1.
- [`modules.md`](./modules.md) — `Env`, `Net`, `Fs`, `KeyValue`,
  `KvPage`, `Audio`, `Midi`, `AiEnv`, `Ui`, `Clock`, `Rng`,
  `Stdout`, `Stderr`, `ExitFn`, `with_capabilities` are auto-prelude. `env` is the
  ambient binding the runtime provides at program entry; it
  does not appear in the auto-prelude name list but is
  resolvable from every function body.
- [`grammar.md`](./grammar.md) — `WithCapsStmt` production
  updated to admit the `use:` overrides; `fn main`-shape entry
  points covered by `FnDecl`.
