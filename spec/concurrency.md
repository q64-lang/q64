# Concurrency

How work is structured in q64. Scopes own tasks. Tasks are virtual
threads on Wasm 3.0 stack-switching. Channels move ownership.
Shared state is opt-in via the `@shared` regions and `Atomic<T>`
primitives from [`memory.md`](./memory.md). The stream runtime is
the task scheduler.

## Design goals

1. **Structured by default.** Every task lives in a scope; scopes
   wait for their children. No leaked tasks, no orphan work.
2. **No function coloring.** No `async fn`, no `.await` syntax tax.
   Suspension is a runtime behavior, made checkable by the effect
   system (`@no_suspend`), not a syntactic obligation.
3. **Cancellation is plumbed, not magic.** A `ctx: Cancel` parameter
   travels with cancel-observing functions. The call site sees it.
4. **Ownership-transfer channels.** Sending consumes; the sender
   cannot reuse the value. `@send` enforces what can cross threads.
5. **One scheduler for tasks and streams.** Stages are tasks;
   stream graphs are task graphs.
6. **The language never names a thread.** Tasks are the unit;
   thread placement is a host/scheduling concern.

## Vocabulary

| Word              | Meaning                                                                          |
|-------------------|----------------------------------------------------------------------------------|
| **scope**         | A structured-concurrency block that owns tasks and an arena (per `memory.md`).   |
| **task**          | A unit of work running on its own coroutine stack.                               |
| **handle**        | A typed reference to a task: `h.await()`, `h.cancel()`. Drop = cancel + join.    |
| **channel**       | Ownership-transferring queue between tasks.                                      |
| **actor**         | A task with private state and a typed message inbox.                             |
| **`ctx`**         | A `Cancel` value threaded through cancel-observing function signatures.          |
| **virtual thread**| A q64 task. M:N onto Wasm threads via stack-switching.                           |

## Scopes

Every task lives in a scope. The scope cannot exit until every
spawned task has completed:

```q64
scope {
    let h1 = spawn { compute_thing_a() }
    let h2 = spawn { compute_thing_b() }

    let a = h1.await()
    let b = h2.await()
}                                       // any unawaited tasks joined here
```

Properties:

- A scope's lifetime bounds every task spawned inside it.
- A scope cannot return a handle to a child task (the handle would
  outlive the scope). `CONC010` ("handle escapes its scope").
- Cancellation propagates parent → child: cancelling a task that
  owns a scope cancels every task inside that scope.
- The scope carries the implicit `scope` arena from
  [`memory.md`](./memory.md). The first `scope` of a function
  body also opens it.
- A scope can declare a `catch` block to handle a child panic
  (see §Panics).

Nested scopes inherit cancellation from the parent and add new
bounds for their own children. Same shape as Swift `TaskGroup`,
Trio nursery, Kotlin `coroutineScope` — picked for the
twenty-year-old safety story, not novelty.

### Scope effect annotations

A `scope` may carry an effect annotation that applies as an
assert to every task spawned directly inside it:

```q64
scope @realtime {
    loop {
        select {
            f = rx_frame.recv(ctx) -> play(move f),
            // cancellation observed at select boundary
        }
    }
}
```

Grammar: `scope (@<effect> ("+" @<effect>)*)? { … } (catch (e: T) { … })*`.
The effect list applies the standard implication closure from
[`effects.md`](./effects.md), then propagates to every task body
inside the scope. A child task whose effect set exceeds the
scope's annotation is `EFF110` at its spawn site.

The combined form `spawn scope @<effect> { … }` is sugar for
`spawn { scope @<effect> { … } }` — it spawns a task whose body
is a single annotated scope. Useful when an `@realtime` worker
needs its own scope but no surrounding parent scope wants the
constraint:

```q64
spawn scope @realtime {
    audio_loop(ctx, rx_frame)
}
```

`@realtime` is by far the most common annotation; `@no_alloc`
and user-defined effects are also legal. Asserts compose; a
`scope @realtime + @no_panic` redundantly tightens (with
`@realtime` already implying `@no_panic`) and is `EFF132` lint.

## Tasks

```q64
spawn { … }                              // fire-and-forget within current scope
let h = spawn { compute() }              // handle for explicit join/cancel
let v = h.await()                        // suspends until done; returns the result
h.cancel()                               // cooperative cancellation (see §Cancellation)
```

A handle is `Handle<T>` where `T` is the body's return type.
`spawn { … }` (no `let`) is `Handle<()>` and may be dropped freely.

### Handle ownership

Dropping a `Handle<T>` cancels the task and waits for it to
acknowledge cancellation before the drop completes:

```q64
scope {
    let h1 = spawn { compute_a() }
    let h2 = spawn { compute_b() }
    let v = h2.await()
    // h1 dropped here → cancelled, awaited, result discarded
}                                       // scope exits as soon as both finish
```

This is a deliberate departure from "auto-join unawaited handles"
(Swift TaskGroup, Trio nursery): explicit cancellation on drop
means a scope exits as soon as its useful work completes, not
when its sibling work happens to finish.

Three ways to dispose of a handle:

| Form          | Behavior                                                          |
|---------------|-------------------------------------------------------------------|
| `h.await()`   | Suspends until done; returns the value; consumes the handle.     |
| `h.cancel()`  | Sends cancellation; consumes the handle; does **not** await.      |
| drop          | Cancel + await acknowledgement. Synchronous within the drop site. |

A handle that has been awaited or cancelled is consumed; using it
again is `CONC011` ("use of consumed handle").

## Virtual threads: M tasks on N Wasm threads

q64 tasks **are** virtual threads. Thousands or millions can
coexist; each costs a few KB of stack, not the megabyte of an OS
thread. The scheduler multiplexes them onto a pool of Wasm
threads:

```
N Wasm threads  =  ≈ CPU cores      (typically 2-32)
M q64 tasks     =  application work (typically 100s-10000s)
```

Same M:N pattern as Goroutines, Java virtual threads (Loom),
Kotlin coroutines, Erlang processes. q64's contribution is
**Wasm 3.0 stack-switching as the primitive** — yielding is a
single Wasm instruction, not a CPS transform or a function-color
rewrite.

Implications:

- **Single-threaded targets** (audio worklet, some Wasmtime
  configurations) get one Wasm thread; tasks still multiplex
  cooperatively. The single-thread case is not a special API —
  it's just `N = 1`.
- **Multi-threaded targets** get a Wasm-thread pool sized to host
  capability. The scheduler does **work-stealing** across Wasm
  threads for tasks whose payload types are `@send` (per
  [`effects.md`](./effects.md)).
- **`@realtime` tasks** are pinned to a real-time-capable Wasm
  thread (audio worklet on browser, low-latency pool on native).
  Migration would break their bounded-time contract.

## Cancellation

A task observes cancellation through an explicit `ctx: Cancel`
parameter. The convention is C-style: `ctx` is the first
parameter; it threads through call trees:

```q64
fn fetch(ctx: Cancel, env: Env, url: str) -> Result<Response, IoError> @cancel {
    var buf: Vec<u8> = Vec.new()
    loop {
        if ctx.cancelled() { panic Cancelled }
        let chunk = try http.read_chunk(ctx, env, url)
        if chunk.is_eof() { break }
        buf.extend(move chunk)
    }
    Ok(Response.parse(buf))
}

scope {
    let h = spawn { fetch(ctx, env, "https://...") }
    sleep(2.s)
    h.cancel()
    h.await()    // panics with Cancelled payload
}
```

`Cancelled` is the auto-prelude payload type from
[`errors.md` §"Auto-prelude payload types"](./errors.md); it fits
`Panic` with `code() = None` — cancellation is a runtime
control-flow event, not a diagnostic, and the `CONC*` codes are
reserved for compile-time diagnostics. Cancellation observation
unwinds the task; it does not consume a recoverable-error slot in
the function's return type.

`Cancel` is an opaque value of type `Cancel`. `ctx.cancelled()`
is `@no_alloc` + `@no_suspend` (cheap to call in hot loops).

The `@cancel` effect documents that a function observes
cancellation. A `@cancel` function calling a non-`@cancel`
function is fine (the callee just doesn't check); a non-`@cancel`
function cannot take a `ctx: Cancel` parameter (per
[`effects.md`](./effects.md), the effect must match the
signature).

### Where `ctx` comes from

Three sources introduce a `ctx: Cancel` binding visible to the
code below:

1. **Function parameter.** A function that declares `ctx: Cancel`
   in its signature receives the caller's `ctx` and forwards it
   to `@cancel` callees. This is the most common path —
   `@cancel` functions take `ctx` as a parameter (§"Cancellation",
   above).
2. **Spawned task.** A `spawn { … }` block introduces a fresh
   `Cancel` named `ctx` that's bound to the handle.
   `h.cancel()` flips that `ctx`; the task sees `ctx.cancelled()`
   go true at its next observation.
3. **Scope binding.** Every `scope { … }` block introduces an
   implicit `ctx: Cancel` whose lifetime is the scope. The scope's
   `ctx` is signalled when the scope's parent task is cancelled or
   when a sibling task panics (per §"Panics across tasks").
   Inside a scope, `ctx` resolves to the **lexically nearest**
   binding: the spawned task's own ctx when inside `spawn { … }`,
   otherwise the enclosing scope's ctx.

`main`'s top-level body has an implicit ctx tied to the program's
lifetime: it never flips (the program ends via `env.exit()` or by
falling off the end), but it allows `@cancel` calls and `select`
arms from inside `main` to type-check. Programs that need to
shut down on a signal (`SIGINT`, browser `beforeunload`) install
a signal handler via the runtime adapter that calls
`top_ctx.cancel()` — the same mechanism as `h.cancel()`.

Cancellation is **cooperative**. `h.cancel()` does not interrupt
running code. The task observes at:

1. Explicit `ctx.cancelled()` checks.
2. Every `select` (see §Select).
3. Channel `recv` / `send` operations on cancel-aware channels
   (`Backpressure` and `LatestValue`; not `RingBuffer` /
   `Unbounded`).
4. Any function that takes `ctx: Cancel` and chooses to check.

Once observed, cancellation unwinds the task via `panic Cancelled`
(per [`errors.md`](./errors.md)); the panic propagates per
§"Panics across tasks", and the nearest enclosing `scope … catch
(e: Cancelled) { … }` (or `catch (e: Panic) { … }`) can intercept
it.

`@realtime` tasks cannot be cancelled at arbitrary points; they
run to their next natural yield. Documented in §Effects.

### `@uncancellable` cleanup

Code that must complete (releasing a lock, flushing a buffer)
opts out of cancellation observation:

```q64
fn flush_journal(env: Env, j: ref Journal) @uncancellable {
    db.write_all(env, j.pending)        // no Cancelled panic even if ctx flips
}
```

The body of an `@uncancellable` function cannot call a `@cancel`
function (the propagation would defeat the marker). `CONC012`.

## Channels

Channels move values between tasks. Sending consumes the value
(move semantics); the sender cannot use it after.

```q64
let (tx, rx) = channel<Frame>(policy: Backpressure, capacity: 16)

spawn {
    let f = capture_frame()
    tx.send(ctx, move f)                 // ownership transferred; suspends if full
}

spawn {
    loop {
        let f = try rx.recv(ctx)         // suspends until a value is available
        render(move f)
    }
}
```

### `channel<T>(…)` construction

`channel<T>(…)` is a built-in factory returning `(Sender<T>,
Receiver<T>)`. **Policy is required** — there is no default. A
bare `channel<T>(capacity: N)` is `CONC050`:

```q64
let (tx, rx) = channel<Cmd>(capacity: 16)
//             ^^^^^^^^^^^^^^^^^^^^^^^^^^ CONC050: channel policy required
```

Forcing the policy at every construction makes the bounded /
overwriting / blocking choice visible at the call site.

The full constructor signature is:

```q64
pub fn channel<T, P: Policy>(
    region:    R     = scope,             // backing allocator; defaults to scope arena
    policy:    P,
    capacity:  i64   = 0,                  // required for Backpressure / RingBuffer
) -> (Sender<T, P>, Receiver<T, P>)
```

- `region` is normally elided; pass an explicit `Pool<T, N>` (per
  [`memory.md`](./memory.md)) to back the channel from a fixed
  slot pool — required when an `@realtime` consumer reads from it
  (see the audio example at the end of this spec).
- `policy` is one of the four below.
- `capacity` is required for `Backpressure` and `RingBuffer`;
  ignored by `LatestValue` (single slot) and `Unbounded` (grows).

### Channel policies

| Policy           | Behavior on overflow                                  |
|------------------|-------------------------------------------------------|
| `Backpressure`   | Sender suspends; resumes when there's room.            |
| `RingBuffer`     | Overwrites the oldest value.                           |
| `LatestValue`    | Single-slot; only the most recent retained.            |
| `Unbounded`      | Grows; never blocks; lints as `CONC051` (advisory).    |

- **`Backpressure`** for lossless data: file streams, network
  protocols, work queues. Cancel-aware (observes `ctx`).
- **`RingBuffer`** for time-windowed data: audio history, log
  tails, sensor traces. Not cancel-aware; never blocks.
- **`LatestValue`** for state mirroring: UI state propagation,
  render-thread "what's the latest?" reads. Cancel-aware.
- **`Unbounded`** for emergencies only; `q64 fmt --lint` warns.

### `Sender<T, P>` and `Receiver<T, P>` API

The endpoints' surface depends on whether the policy is
cancel-aware (`Backpressure`, `LatestValue`) or not
(`RingBuffer`, `Unbounded`). Two pairs of faces; the
`channel<T, P>(…)` factory returns the variant matching `P`.

```q64
// Common methods on every Sender / Receiver
pub face SenderBase<T, P: Policy> {
    fn try_send (self, move x: T) -> Result<(), SendError<T>>   // never suspends
    fn close    (self)                                          // signal end-of-stream
}

pub face ReceiverBase<T, P: Policy> {
    fn try_recv (self) -> Result<T, RecvError>                  // never suspends
    fn closed   (self) -> bool
}

// Non-cancel-aware policies — send/recv never observe ctx
pub face Sender<T, P: NonCancelPolicy> : SenderBase<T, P> {
    fn send (self, move x: T)                                   // never suspends (RingBuffer overwrites; Unbounded grows)
}

pub face Receiver<T, P: NonCancelPolicy> : ReceiverBase<T, P> {
    fn recv (self) -> T                                         // suspends but does not observe cancellation
}

// Cancel-aware policies — send/recv take ctx and are @cancel
pub face Sender<T, P: CancelPolicy> : SenderBase<T, P> {
    fn send (self, ctx: Cancel, move x: T) @cancel              // may unwind via panic Cancelled
}

pub face Receiver<T, P: CancelPolicy> : ReceiverBase<T, P> {
    fn recv (self, ctx: Cancel) -> T @cancel                    // suspends; observes cancellation
}
```

`Policy` is the auto-prelude umbrella face;
`CancelPolicy` and `NonCancelPolicy` are its two disjoint
sub-faces. `Backpressure` and `LatestValue` fit `CancelPolicy`;
`RingBuffer` and `Unbounded` fit `NonCancelPolicy`. The compiler
picks the correct `Sender`/`Receiver` fit per the policy at the
channel-construction site.

Notes:

- `recv` returns `T` directly; it does **not** return a `Result`.
  End-of-stream is detected via `closed()` or by the `for x in rx
  { … }` loop form (below).
- Calling `recv` on a closed-and-empty channel unwinds the task
  with `panic Closed` — `Closed` is the auto-prelude
  `Panic`-fitting payload from
  [`errors.md` §"Auto-prelude payload types"](./errors.md). A
  receiver that wants to observe close cleanly tests `closed()`
  first or iterates with `for x in rx { … }`.
- `try_recv` returns `Err(RecvError::Empty)` when no value is
  ready and `Err(RecvError::Closed)` when the sender has closed
  and the buffer is empty.
- `SendError<T>` carries the rejected value back so the caller can
  recover ownership on failure: `Err(SendError { value: T, reason:
  SendErrorReason })` where `SendErrorReason ∈ { Full, Closed }`.

### `for x in rx { … }` loop form

`Receiver<T, P>` does **not** fit the auto-prelude `Iterator` face
— `Iterator.next() -> Item?` is non-suspending, and `recv` needs
to suspend (possibly observing cancellation). The `for x in rx {
body }` form is a compiler-recognized desugaring, not an
`Iterator` fit:

```q64
for x in rx { body(x) }
```

desugars per the receiver's policy. For a cancel-aware policy
(`Backpressure`, `LatestValue`):

```q64
loop {
    match rx.try_recv() {
        Ok(x)                  -> body(x),
        Err(RecvError::Empty)  -> { let x = rx.recv(ctx); body(x) },
        Err(RecvError::Closed) -> break,
    }
}
```

For a non-cancel-aware policy (`RingBuffer`, `Unbounded`):

```q64
loop {
    match rx.try_recv() {
        Ok(x)                  -> body(x),
        Err(RecvError::Empty)  -> { let x = rx.recv(); body(x) },     // no ctx
        Err(RecvError::Closed) -> break,
    }
}
```

Requirements: for a cancel-aware policy, a `ctx: Cancel` must be
in lexical scope (the desugaring uses it for the suspending
`recv`). A `for x in rx` over a `CancelPolicy` channel with no
`ctx` in scope is `CONC053` ("for-loop over cancel-aware
receiver without ctx"). For a non-cancel-aware policy, `ctx` is
not required.

### Cross-thread channels

The channel API is the same whether the endpoints are on one
thread or two. The runtime adapter chooses the backing:

- **Same-thread** endpoints: in-memory ring buffer, no atomics.
- **Cross-thread** endpoints: SAB-backed ring buffer with
  `Atomics.wait/notify` (browser) or futex (native).

User code is identical. The runtime picks the implementation
based on whether the endpoints end up in different shared
scopes. Cross-thread channels require the payload type to be
`@send` (per [`effects.md`](./effects.md)); the check happens at
`channel<T>(…)` construction if the channel will be passed across
a thread boundary.

## Select

`select` waits for the first ready branch and dispatches:

```q64
select {
    msg = rx1.recv(ctx) -> handle_message(move msg),
    cmd = rx2.recv(ctx) -> handle_command(move cmd),
    _   = timeout(100.ms) -> handle_timeout(),
}
```

Timeouts and channels are uniform: `timeout(d)` returns a
`Receiver<()>` that fires once after `d` elapses.

### Implicit cancellation branch

Every `select` carries an implicit cancellation branch resolved
to the lexically nearest `ctx: Cancel`:

```q64
fn worker(ctx: Cancel, rx: Receiver<Cmd, Backpressure>) {
    loop {
        select {
            cmd = rx.recv(ctx) -> handle(cmd),
            _   = timeout(1.s) -> tick(),
            // _ = ctx.cancelled() -> panic Cancelled   ← implicit
        }
    }
}
```

The injected branch unwinds with `panic Cancelled`. A user-written
`_ = ctx.cancelled() -> …` branch overrides the default for
cleanup-before-unwinding:

```q64
select {
    msg = rx.recv(ctx)   -> handle(move msg),
    _   = ctx.cancelled() -> { flush(env); panic Cancelled },
}
```

If no `ctx: Cancel` is in scope, `q64 fmt --lint` warns
(`CONC041`) — the `select` will wait forever.

## Actors

A task with private state and a typed message inbox. The actor
*type* enforces invariants that a bare desugaring would not.

```q64
actor Counter {
    state count: i64 = 0

    handle Increment {
        state.count += 1
    }

    handle Get -> i64 {
        state.count
    }
}

scope {
    let c = Counter.spawn()
    c.tell(Increment)
    c.tell(Increment)
    let n = c.ask(Get).await()           // 2
}
```

### `tell` vs `ask`

Two verbs split by reply semantics:

| Verb            | Used for handlers declared as     | Returns         |
|-----------------|-----------------------------------|-----------------|
| `c.tell(Msg)`   | `handle Msg { … }` (no `-> T`)    | `()`            |
| `c.ask(Msg)`    | `handle Msg -> T { … }`           | `Future<T>`     |

Cross-use is a compile error:

```q64
c.tell(Get)        // ← CONC020: handler `Get` declares a reply; use `ask`
c.ask(Increment)   // ← CONC021: handler `Increment` has no reply; use `tell`
```

`Future<T>.await()` suspends until the reply arrives. A `Future`
is consumed by `await`; dropping a `Future` is fine (the reply is
discarded).

### Properties enforced by the actor type

- **Isolation.** Outside code cannot read or write `state` fields
  directly — only by sending messages. `CONC022`.
- **Serial.** One message processed at a time; no re-entrancy.
- **Crossable.** Actor handles are `@send` by construction; they
  can be passed across threads.
- **Lifetime-bound.** `Counter.spawn()` inside a `scope { … }`
  ties the actor's lifetime to that scope.

### Desugared form

`Counter` desugars to roughly:

```q64
enum CounterMsg {
    Increment,
    Get(reply: Sender<i64>),
}

fn run_counter(ctx: Cancel, rx: Receiver<CounterMsg, Backpressure>) {
    var count: i64 = 0
    loop {
        select {
            msg = rx.recv(ctx) -> match msg {
                Increment    -> count += 1,
                Get(reply)   -> reply.send(count),
            },
        }
    }
}
```

The actor sugar is this shape lifted into the type system, with
field-access discipline checked by the compiler.

## Shared state

Default: every region is thread-local. Sharing is opt-in via the
`@shared` annotation and `Atomic<T>` / `Shared<T, P>` primitives
specified in [`memory.md`](./memory.md):

```q64
@shared
struct World {
    counter: Atomic<i64>,
    grid:    Shared<Grid, RwLock>,
}

scope {
    let world = World.new()
    spawn { world.counter.add(1) }
    spawn { world.counter.add(1) }
    // world.counter == 2 at scope exit
}
```

See `memory.md` §"Shared regions" for the full table of policies
(`Mutex / RwLock / LockFree / Disjoint<F>`) and §"`Atomic<T>`"
for the primitive operations.

`@send` is derived (per [`effects.md`](./effects.md)): types
containing only `@send` fields are `@send`. The cross-thread
channel check uses this derivation to reject sharing a
non-shareable value at compile time.

## Panics across tasks

A failing task's behavior depends on whether its scope declares
a `catch`. Panic payloads — typed per [`errors.md` §"`panic` and
`trap`"](./errors.md) — flow from the failing task to the
enclosing scope, optionally intercepted by a `catch` arm.

### Without `catch`: cancel siblings, re-panic at scope close

```q64
scope {
    spawn { db.connect() }              // panics
    spawn { cache.warm() }              // cancelled when sibling panics
    do_other_work()
}
// ← panic re-emerges here, into the parent scope, with the same payload
```

The first panic in a child:

1. Marks the scope as failing.
2. Cancels every sibling task (signals their `ctx`, which observes
   it at its next yield point and unwinds via `panic Cancelled`).
3. Waits for siblings to acknowledge.
4. Re-panics with the original payload at the scope's closing brace.

No silent loss. No orphan work.

### With `catch`: intercept the panic, suppress propagation

```q64
scope {
    spawn { db.connect() }
    spawn { cache.warm() }
    do_other_work()
} catch (e: Panic) {
    log.error("subsystem startup failed: {e.fmt()}")
    bring_up_degraded_mode()
}
```

If any child panics, siblings are cancelled (same as above) but
the panic's payload is delivered to the first matching `catch` arm
instead of re-panicking. The scope completes normally after the
`catch` returns.

A `catch` block runs after every child task has finished (either
normally or by cancellation). It cannot spawn new tasks into the
just-closed scope; spawning in `catch` is `CONC030`.

### Typed `catch` arms

A `scope` may have one or more `catch` arms; each binds the
payload by type. Arms are tried top-down, most-specific first.
A `catch (e: Panic)` (or `catch (e: dyn Panic)` — equivalent
syntax) is the catch-all.

```q64
scope {
    spawn { fetch_with_timeout(ctx, env, url, 30.s) }
} catch (e: Cancelled) {
    env.out("shutting down cleanly")
} catch (e: RuntimeDenied) {
    log.warn("denied: {e.code} — {e.detail}")
} catch (e: Panic) {
    log.error("unexpected: {e.fmt()}")
}
```

- A `catch (e: T)` arm matches when the panic payload's runtime
  type fits `T` and `T` itself fits `Panic`. Non-`Panic` types in
  catch position are `TYP307`.
- Unmatched panics fall through to the next arm; an unmatched
  panic with no further arms re-panics at the scope's closing
  brace (per §"Without `catch`").
- Re-panic from inside a `catch (e: …)` body uses `panic e` (per
  `errors.md`) — there is no separate keyword.
- Two arms with the same type, or a catch-all arm preceding a
  more specific one, are `CONC033` ("unreachable catch arm").

### `Result`-returning tasks

A spawned task that returns `Result<T, E>` does not "panic" when
returning `Err(e)`; the error is delivered through
`h.await()`. Only an actual `panic` / `trap` invokes the scope
unwinding above.

A stage inside a `graph { … }` is the exception: stages have no
`h.await()` consumer, so a stage returning `Err` is converted to
a panic at the stage boundary and cascades per the rules above.
This is specified in [`streams.md` §"Error propagation"](./streams.md).

```q64
scope {
    let h = spawn { connect_to_db() }    // returns Result<Conn, Error>
    match h.await() {
        Ok(conn) -> use_db(conn),
        Err(e)   -> log.error("db unavailable: {e}"),
    }
}
```

## Coroutines (no async/await coloring)

Wasm 3.0 stack-switching means q64 doesn't need function colors.
There is no `async fn`, no `.await` syntax at I/O call sites, no
"what color is your function" problem:

```q64
fn fetch_user(ctx: Cancel, env: Env, id: UserId) -> User {
    let resp = http.get(ctx, env.net, url_for(id))     // suspends here
    parse_user(resp.body)
}
```

`fetch_user` is just a function. The HTTP call suspends the task;
another task runs; when the response arrives, the task resumes
from the exact instruction. Callers don't have to annotate
themselves.

The compiler still tracks "this function can suspend" via the
`@no_suspend` effect (per [`effects.md`](./effects.md)). A
`@no_suspend` function calling something that suspends is
`EFF111`. The `@realtime` effect implies `@no_suspend`.

## Effects across concurrency

The effect markers from [`effects.md`](./effects.md) apply to
tasks and channels:

| Marker        | Meaning                                                       |
|---------------|---------------------------------------------------------------|
| `@realtime`   | Bounded execution, no alloc, no blocking, no suspending.      |
| `@no_alloc`   | No heap allocation (linear or managed).                       |
| `@no_suspend` | Cannot yield to the scheduler.                                |
| `@send`       | Safe to transfer across thread boundaries.                    |
| `@pure`       | No mutation, no observable side effects.                      |
| `@cancel`     | Function observes `ctx.cancelled()`.                          |

Specific interactions:

- A `@realtime` stage cannot call a non-`@realtime` function or
  send on a `Backpressure` channel (which would block). Use
  `RingBuffer` or `LatestValue` (non-blocking).
- A `@realtime` task is pinned to a real-time-capable Wasm thread;
  cannot be migrated.
- Cross-thread channels require the payload to be `@send`. The
  compiler verifies the graph at build time.
- `@cancel` cannot appear in `@uncancellable` call trees.
- `@uncancellable` cannot appear in `@realtime` (cancellation is
  already moot in real-time; the marker would just confuse).

The graph is verified at build time — runtime surprises (audio
glitches, deadlocks, sharing violations) get caught as type
errors.

## Threading: a host concern

The language never names a thread. Tasks are the unit; whether
two tasks happen to run on the same OS thread or different ones
is a scheduling decision made by the runtime adapter.

| Host        | Coroutines        | Multi-threading       | Channels                   | Atomics                  |
|-------------|-------------------|-----------------------|----------------------------|--------------------------|
| Browser     | Wasm stack-switch | Web Workers + SAB     | SAB ring + Atomics.wait    | `Atomics.load/store/cas` |
| Wasmtime    | Wasm stack-switch | OS threads            | shared-memory ring         | futex / pthread atomic   |
| Wasmer      | Wasm stack-switch | OS threads            | shared-memory ring         | futex / pthread atomic   |
| Audio host  | host scheduler    | audio worklet thread  | host-managed lock-free FIFO| host primitives          |

User code is identical across all. The runtime adapter translates
q64's `scope` / `spawn` / `channel` primitives to platform
mechanisms. SAB, `Worker.postMessage`, `Atomics.*`, COOP/COEP
headers — all behind the adapter, never in user code.

The one thing that leaks through is deployment configuration:
COOP/COEP headers, thread-pool sizes, audio-worklet affinity.
These live in `qube.json5` target profiles, not in the language.

### Encapsulating SharedArrayBuffer

What user code never touches:

- `SharedArrayBuffer`, `ArrayBuffer.transferToFixedLength`
- `Worker`, `Worker.postMessage`, `MessagePort`
- `Atomics.wait`, `Atomics.notify`, `Atomics.compareExchange`
- `BigInt` marshaling for `i64` across the JS boundary
- COOP/COEP headers in HTML/HTTP responses
- Wasm thread bootstrap (creating shared memory, initializing
  workers)

What user code does see:

- `scope`, `spawn`, `channel<T>`, `select`
- `@shared`, `Atomic<T>`, `Shared<T, P>` (per `memory.md`)
- `actor`, `handle`, `tell`, `ask`
- `Signal<T>`, `Event<T>`, `Stream<T>` (per [`streams.md`](./streams.md))

The runtime adapter is the boundary. Application code is
portable across browser, Wasmtime, and audio-host targets without
changing a line.

## Stream runtime = task scheduler

There is no separate "async runtime" alongside the stream graph
executor. They're the same.

- Each `stage` in a stream graph is a task.
- Stream channels (`|>` between stages) are the channel system
  above.
- Adjacent stages with compatible effects can be **fused** by the
  compiler into a single task — one suspension point per fused
  group, fewer context switches, better SIMD usage.
- Backpressure propagates through the graph automatically.
- `@realtime` graph segments get pinned to real-time-capable
  threads.

Audio DSP, a UI event loop, an LLM token pipeline, and a worker
queue all use the same primitives, the same scheduler, and the
same effect-checking. One concurrency story for the whole
language.

Detailed in [`streams.md`](./streams.md).

## Diagnostic codes

All concurrency diagnostics use the `CONC` prefix. Numbers stable,
never reused. `CONC060`-`CONC099` reserved for expansion.

## Grammar (informal)

```
ScopeStmt    := "scope" EffectAnnot? Block CatchArm*
EffectAnnot  := "@" Ident ("+" "@" Ident)*
CatchArm     := "catch" "(" Ident ":" TypeExpr ")" Block

SpawnExpr    := "spawn" Block
              | "spawn" "scope" EffectAnnot? Block       // sugar
              | "spawn" "scope" EffectAnnot? Block CatchArm*

ActorDecl    := Visibility? "actor" Ident ActorBody
ActorBody    := "{" ActorItem* "}"
ActorItem    := StateDecl | HandleDecl
StateDecl    := "state" Ident ":" TypeExpr ("=" Expr)?
HandleDecl   := "handle" Ident ("(" Params? ")")? ("->" TypeExpr)? Block

ChannelExpr  := "channel" "<" TypeExpr ("," PolicyExpr)? ">"
                  "(" ChanArgs ")"
ChanArgs     := (RegionArg ",")? "policy" ":" PolicyExpr ("," "capacity" ":" Expr)?

SelectStmt   := "select" "{" SelectArm ("," SelectArm)* ","? "}"
SelectArm    := (Pattern "=")? Expr "->" (Block | Expr)
```

`ActorDecl` joins the top-level `Item` list in
[`modules.md`](./modules.md) §Grammar; `pub effect` declarations
introduced in [`effects.md`](./effects.md) do the same. The
`EffectAnnot` form on `scope` reuses the same `@<ident>` syntax as
function-level effect annotations from `effects.md`.

| Code     | Short message                                | When                                                                              |
|----------|----------------------------------------------|-----------------------------------------------------------------------------------|
| `CONC010`| handle escapes its scope                     | A function returns a `Handle<T>` whose task was spawned in one of its scopes.     |
| `CONC011`| use of consumed handle                       | `.await()` / `.cancel()` called on an already-disposed handle.                    |
| `CONC012`| `@cancel` call from `@uncancellable` context | A function marked `@uncancellable` calls one marked `@cancel`.                    |
| `CONC013`| `@uncancellable` inside `@realtime`          | The two markers are mutually meaningless; flagged at definition.                  |
| `CONC020`| `tell` on a reply-bearing handler            | `c.tell(Get)` where `handle Get -> T` is declared.                                |
| `CONC021`| `ask` on a non-reply handler                 | `c.ask(Increment)` where `handle Increment { … }` (no `-> T`) is declared.        |
| `CONC022`| outside access to actor `state`              | Code outside the actor reads or writes a `state` field directly.                  |
| `CONC030`| `spawn` inside a `catch` block               | `catch` may not start new tasks into the just-closed scope.                       |
| `CONC031`| `spawn` outside any `scope`                  | The top-level `spawn` requires an enclosing scope (or the implicit `main` scope). |
| `CONC032`| `actor` handler not declared in face         | `c.tell(Msg)` / `c.ask(Msg)` where `Msg` is not a declared `handle`.              |
| `CONC033`| unreachable `catch` arm                      | A later `catch` arm cannot be reached because an earlier arm subsumes it.         |
| `CONC040`| `select` without timeout or cancel branch    | Lint (advisory). Suppressible with `@allow(CONC040)`.                             |
| `CONC041`| `select` with no `ctx: Cancel` in scope      | Lint. The implicit cancel branch can't resolve; `select` may hang forever.         |
| `CONC050`| channel policy required                      | `channel<T>(capacity: N)` with no `policy:` argument.                              |
| `CONC051`| `Unbounded` channel                          | Lint (advisory). `channel<T>(policy: Unbounded)`.                                  |
| `CONC052`| non-`@send` payload in cross-thread channel  | A channel passed across a thread boundary whose `T` isn't `@send`.                |
| `CONC053`| `for x in rx` over cancel-aware receiver without `ctx` | The for-loop desugaring needs a `ctx: Cancel` for the suspending `recv(ctx)` step on `Backpressure`/`LatestValue` policies. |

All codes are emitted using the envelope from
[`diagnostics.md`](./diagnostics.md).

## Examples

### Cancellation-aware HTTP client

```q64
fn fetch_with_retry(
    ctx: Cancel,
    env: Env,
    url: str,
    max_attempts: i64,
) -> Result<Response, Error> @cancel {
    for attempt in 0..max_attempts {
        if ctx.cancelled() { panic Cancelled }
        match http.get(ctx, env.net, url) {
            Ok(r)  -> return Ok(r),
            Err(_) -> sleep(ctx, backoff(attempt)),
        }
    }
    Err(Error.new("exceeded retries"))
}

scope {
    let h = spawn { fetch_with_retry(ctx, env, "https://...", 3) }
    select {
        r = h.await()         -> use_response(r),
        _ = timeout(10.s)     -> h.cancel(),
    }
}
```

### Producer / consumer with backpressure

```q64
scope {
    let (tx, rx) = channel<Frame>(policy: Backpressure, capacity: 8)

    spawn {
        loop {
            let f = capture(env.camera)
            tx.send(ctx, move f)              // suspends if buffer full
        }
    }

    spawn {
        loop {
            let f = rx.recv(ctx)
            encode_and_write(env, move f)
        }
    }
}
```

### Actor with reply

```q64
actor Cache {
    state entries: Map<str, Value> = Map.new()

    handle Put(key: str, value: Value) {
        state.entries.insert(move key, move value)
    }

    handle Get(key: str) -> Option<Value> {
        state.entries.get(key).cloned()
    }
}

scope {
    let cache = Cache.spawn()
    cache.tell(Put("user/42", Value.from(user)))
    let v = cache.ask(Get("user/42")).await()
    print(v)
}
```

### Panic recovery at scope boundary

```q64
fn boot(env: Env) {
    scope {
        spawn { primary_db(env) }
        spawn { primary_cache(env) }
        spawn { primary_search(env) }
    } catch (e: Panic) {
        log.warn("primary startup failed: {e}")
        scope {
            spawn { fallback_db(env) }
            spawn { fallback_cache(env) }
        }
    }
}
```

### Real-time audio with shared command channel

```q64
fn audio_engine(env: Env) {
    region pool: Pool<Frame, 64> {
        let (tx_frame, rx_frame) =
            channel<Frame>(policy: RingBuffer, capacity: 64)
        let (tx_cmd, rx_cmd) =
            channel<Command>(policy: LatestValue)

        spawn { capture_loop(ctx, env, tx_frame) }

        spawn scope @realtime {
            loop {
                select {
                    f   = rx_frame.recv(ctx) -> play(move f),
                    cmd = rx_cmd.recv(ctx)   -> apply(cmd),
                    // implicit cancel branch
                }
            }
        }

        ui_loop(env, tx_cmd)
    }
}
```

The `@realtime` scope cannot suspend on a `Backpressure` channel;
`RingBuffer` and `LatestValue` are non-blocking. Cancellation is
observed at the `select` boundary, where the realtime thread can
clean up bounded resources before exit.

## Open items deferred

- **Stage / graph DSL.** The `stage` and `graph` keywords from
  the design doc — fusion rules, pipe `|>` semantics, backpressure
  propagation — live in [`streams.md`](./streams.md).
- **`select` with `default` (non-blocking poll).** Common in Go;
  deferred for v0. Workaround: `timeout(0.ms)`.
- **Task-local storage.** Go's `context.Value`, Trio's run-vars.
  Today: passed via `env` or actor state.
- **Detached tasks.** Tasks that survive scope close. Deliberately
  unsupported; structured concurrency requires it.
- **Custom schedulers.** v0 ships one work-stealing scheduler with
  a `@realtime` pinning lane. Per-graph scheduler overrides
  deferred.
- **Per-channel priority.** All channels are equal; priority is
  encoded by select ordering. May add `priority: Priority`
  argument later.

## Related specs

- [`memory.md`](./memory.md) — scope's implicit arena, `@shared`,
  `Atomic<T>`, `Shared<T, P>` policies, `transfer(to: …)`,
  multi-memory layout.
- [`effects.md`](./effects.md) — `@realtime`, `@no_suspend`,
  `@send`, `@cancel`, `@pure`; the implication graph and `@send`
  derivation that channel and shared-state checks rely on.
- [`errors.md`](./errors.md) — `Result<T, E>`, `panic`, `Cancelled`
  (a structured-cancellation error type).
- [`generics.md`](./generics.md) — generic parameters on `Sender<T>`,
  `Receiver<T>`, `Handle<T>`, `Future<T>`.
- [`faces.md`](./faces.md) — `Sender`, `Receiver`, `Handle`, the
  `Actor` blessed pattern.
- [`streams.md`](./streams.md) — `stage`, `graph`, the dataflow
  DSL; the stream runtime that **is** this scheduler.
- [`modules.md`](./modules.md) — `scope`, `spawn`, `channel`,
  `select`, `actor`, `tell`, `ask`, `Cancel`, `Handle`, `Future`,
  `timeout`, `sleep` are auto-prelude; no import required.
- [`diagnostics.md`](./diagnostics.md) — envelope format for the
  `CONC*` codes.
