# q64 — Concurrency

The most important part of a streams-first language is how work is structured, how data flows between tasks, and how the platform's threading complexity is hidden. q64's answer: **structured scopes + ownership-transfer channels + stack-switching coroutines**, with shared state opt-in and SharedArrayBuffer / Workers / Atomics fully encapsulated by the runtime adapter.

## The core model

- **Scopes** own tasks and allocators. Tasks cannot outlive their scope.
- **Tasks** are lightweight, running on coroutine stacks via Wasm 3.0 stack-switching.
- **Channels** transfer ownership of values between tasks. The sender cannot use a value after sending.
- **Shared state** is opt-in via `Shared[T]` or explicit shared regions; the default is thread-local.
- **No function coloring.** No `async fn` / `await` distinction. A task suspends transparently when it waits on a channel, signal, or I/O.
- **The stream runtime *is* the async runtime.** Stages are tasks. Stream graphs are task graphs. One scheduler handles both.

## Scopes

Structured concurrency. Every task lives in a scope; the scope cannot exit until all child tasks complete:

```q64
scope {
    let h1 = spawn { compute_thing_a() }
    let h2 = spawn { compute_thing_b() }

    let a = h1.await()
    let b = h2.await()
}
// any unawaited tasks are joined here automatically
```

No leaked tasks. No orphan work. Cancellation propagates from parent scope to children. Same shape as Swift's TaskGroup, Trio's nursery, Kotlin's `coroutineScope` — picked for proven safety, not novelty.

Nested scopes inherit cancellation from their parent and add new bounds for their own children.

## Tasks

```q64
spawn { ... }                    // fire-and-forget within current scope
let h = spawn { compute() }      // handle for explicit join/cancel
let v = h.await()                // suspends until done; returns the result
h.cancel()                       // cooperative cancellation
```

Cancellation is cooperative — a task observes `ctx.cancelled()` at suspension points or in long loops. `@realtime` tasks cannot be cancelled at arbitrary points; they run to their next natural yield. The effect system makes this visible at the call site.

## Virtual threads: M tasks on N Wasm threads

q64 tasks **are** virtual threads. Thousands or millions can exist concurrently; each costs a few KB of stack, not the megabyte of an OS thread. The scheduler multiplexes them onto a small pool of Wasm threads (OS threads in native hosts, Web Workers in the browser).

```
N Wasm threads  =  ≈ CPU cores      (typically 2–32)
M q64 tasks     =  application work (typically 100s–10000s)
```

Same M:N pattern as Goroutines on Go's scheduler, Java virtual threads on Project Loom, Kotlin coroutines, Erlang processes on the BEAM. Familiar architecture; q64's contribution is using **Wasm 3.0 stack-switching as the implementation primitive** instead of CPS transforms or coloring.

This is part of *why* q64 commits to Wasm 3.0. Without stack-switching, the alternatives are function coloring (the async/await tax) or a CPS-transformed runtime (heavy on code size and debugging difficulty). Stack-switching gives full virtual threads cheaply — yielding is a Wasm instruction, not a compiler-rewritten state machine.

Implications:

- **Single-threaded targets** (audio worklet, some Wasmtime configurations) get one Wasm thread; tasks still multiplex onto it cooperatively. The single-thread case is not a special API — it's just `N = 1`.
- **Multi-threaded targets** get a Wasm-thread pool sized to host capability. The scheduler does **work-stealing** across Wasm threads for tasks whose payload types are `@send`.
- **`@realtime` tasks** are pinned to a real-time-capable Wasm thread (audio worklet on browser, low-latency pool on native). Migration would break their bounded-time contract.
- **Stack growth** is cheap and segmented; tasks don't need conservative stack reservations like OS threads do.

So "virtual threads on top of Wasm threads" isn't an *added* layer — it's the model from the start. Wasm threads are the resource; tasks are the unit; the scheduler is what bridges them.

## Channels

Channels move values between tasks. Sending consumes the value (move semantics); the sender cannot use it after.

```q64
let (tx, rx) = channel[Frame](capacity: 16)

spawn {
    let f = capture_frame()
    tx.send(move f)            // ownership transferred
}

spawn {
    loop {
        let f = rx.recv()      // suspends until a value is available
        render(move f)
    }
}
```

### Channel policies

Different domains want different overflow behavior. q64 makes the choice explicit at construction:

```q64
channel[T](policy: Backpressure, capacity: N)    // sender suspends when full
channel[T](policy: RingBuffer,   capacity: N)    // overwrites oldest on overflow
channel[T](policy: LatestValue)                  // single slot, only the most recent retained
channel[T](policy: Unbounded)                    // grows; dangerous, lints as advisory warning
```

- **Backpressure** for lossless data: file streams, network protocols, work queues.
- **RingBuffer** for time-windowed data: audio history, log tails, sensor traces.
- **LatestValue** for state mirroring: UI state propagation, render-thread "what's the latest?" reads.
- **Unbounded** for emergencies only; in practice you almost always want a bounded form.

### Cross-thread channels

The channel API is the same whether the endpoints are on one thread or two. The runtime adapter chooses the backing:

- Same-thread: in-memory ring buffer, no atomics.
- Cross-thread: SAB-backed ring buffer with `Atomics.wait/notify` (browser) or futex (native).

User code is identical across the two — the runtime picks the implementation based on whether the endpoints end up in different shared scopes.

### Selecting on multiple channels

```q64
select {
    msg = rx1.recv()     -> handle_message(move msg),
    cmd = rx2.recv()     -> handle_command(move cmd),
    _   = timeout(100.ms) -> handle_timeout(),
    _   = ctx.cancelled() -> break,
}
```

`select` waits for the first ready branch and dispatches. Timeouts and cancellation are channels too, so they compose with the same primitive.

## Coroutines (no async/await coloring)

Wasm 3.0's stack-switching means q64 doesn't need function colors. There is no `async fn` keyword, no `.await` syntax sprinkled through call sites, no "what color is your function" problem.

```q64
fn fetch_user(env: Env, id: UserId): User {
    let resp = http.get(env.net, url_for(id))     // suspends here
    parse_user(resp.body)
}
```

`fetch_user` is just a function. The HTTP call suspends the task; another task runs; when the response arrives, the task resumes from the exact instruction. Callers don't have to annotate themselves.

The compiler still tracks "this function can suspend" via the effect system — `@no_suspend` is a checkable effect for hot paths that must not yield (audio callbacks, signal handlers, busy loops). A `@no_suspend` function calling something that suspends is a compile error.

## Actors

The pattern "a task with private state and a message channel" shows up often enough to deserve language sugar. The sugar compiles to scope + task + channel + sum type, but the actor *type* enforces invariants that the bare desugaring would not.

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
    c.send(Increment)
    c.send(Increment)
    let n = c.send(Get).await()    // 2
}
```

Properties enforced by the actor type:

- **Isolation.** Outside code cannot read or write `state` fields directly — only by sending messages.
- **Serial.** One message processed at a time; no re-entrancy.
- **Crossable.** Actors are inherently `@send` — their handle can be passed across threads.
- **Lifetime-bound.** Hosting them in a scope ties their lifetime to that scope.

Desugared, `Counter` looks like:

```q64
enum CounterMsg {
    Increment,
    Get(reply: Channel[i64]),
}

fn run_counter(rx: Channel[CounterMsg]) {
    let mut count: i64 = 0
    loop {
        match rx.recv() {
            Increment    -> count += 1,
            Get(reply)   -> reply.send(count),
        }
    }
}
```

The actor sugar is *just* this shape lifted into the type system, with the field-access discipline enforced by the compiler.

## Shared state

Default: every region is thread-local. Sharing is opt-in:

```q64
shared_region world {
    counter: atomic[i64] = 0,
    grid:    Shared[Grid] = Grid.new(world),
}

scope {
    spawn { world.counter.add(1) }
    spawn { world.counter.add(1) }
    // world.counter is now 2
}
```

- **`atomic[T]`** — primitive shared variables, wraps Wasm atomic ops (`add`, `cas`, `load`, `store`).
- **`Shared[T]`** — shared aggregate state, wraps a value with its synchronization protocol (mutex, RwLock, lock-free, or compile-time-verified disjoint access).
- **`shared_region`** — a whole arena of shared data, backed by SAB in the browser and shared linear memory in native hosts.

`@send` markers on types catch "trying to share a non-shareable value" at compile time. Most plain-value types are `@send` by default; managed (GC) types are not, because their GC root lives in a particular thread's arena.

## Errors across tasks

A failing task propagates its error to the scope on `.await()`:

```q64
scope {
    let h = spawn { connect_to_db() }

    match h.await() {
        Ok(conn) -> use_db(conn),
        Err(e)   -> log.error("db unavailable: {e}"),
    }
}
```

If a task panics, the scope unwinds: sibling tasks are cancelled, the scope's allocator is released, and the panic propagates to the parent scope. Structured concurrency means failures don't leak — uncaught errors crash deterministically rather than orphaning workers.

## Threading: a host concern

The language never names "thread." That's deliberate. Tasks are the unit; whether two tasks happen to run on the same OS thread or different ones is a scheduling decision made by the runtime adapter.

| Host        | Coroutines        | Multi-threading       | Channels                   | Atomics                  |
|-------------|-------------------|-----------------------|----------------------------|--------------------------|
| Browser     | Wasm stack-switch | Web Workers + SAB     | SAB ring + Atomics.wait    | `Atomics.load/store/cas` |
| Wasmtime    | Wasm stack-switch | OS threads            | shared-memory ring         | futex / pthread atomic   |
| Wasmer      | Wasm stack-switch | OS threads            | shared-memory ring         | futex / pthread atomic   |
| Audio host  | host scheduler    | audio worklet thread  | host-managed lock-free FIFO| host primitives          |

User code is identical across all of these. The runtime adapter translates q64's task/scope/channel primitives to the platform mechanisms. SAB, `Worker.postMessage`, `Atomics.*`, COOP/COEP headers — all behind the adapter, never in user code.

The one thing that *does* leak through is deployment configuration: COOP/COEP headers, thread pool sizes, audio-worklet affinity. These live in `qube.json5` target profiles, not in the language.

## Encapsulating SAB

What user code never touches:

- `SharedArrayBuffer`, `ArrayBuffer.transferToFixedLength`
- `Worker`, `Worker.postMessage`, `MessagePort`
- `Atomics.wait`, `Atomics.notify`, `Atomics.compareExchange`
- `BigInt` marshaling for i64 across the JS boundary
- COOP/COEP headers in HTML/HTTP responses
- Wasm thread bootstrap (creating the shared memory, initializing workers)

What user code does see:

- `scope`, `spawn`, `channel[T]`, `select`
- `Shared[T]`, `atomic[T]`, `shared_region`
- `actor`, `handle`
- `Signal[T]`, `Event[T]`, `Stream[T]` (language-level dataflow)

The runtime adapter is the boundary. Its job is to translate the q64 vocabulary into platform primitives — picking SAB-vs-postMessage, choosing Worker pool size, handling the i64 → BigInt boundary, configuring header policies via the dev server. Application code is portable across browser, Wasmtime, and audio-host targets without changing a line.

## Effects across concurrency

The effect system applies to tasks and channels as it does to ordinary functions:

| Marker         | Meaning                                                       |
|----------------|---------------------------------------------------------------|
| `@realtime`    | Bounded execution, no alloc, no blocking, no suspending.      |
| `@no_alloc`    | No heap allocation (linear or managed).                       |
| `@no_suspend`  | Cannot yield to the scheduler.                                |
| `@send`        | Safe to transfer across thread boundaries.                    |
| `@pure`        | No mutation, no observable side effects.                      |

A `@realtime` stage cannot call a non-realtime function or send on a backpressure channel (which would block). Cross-thread channels require their payload type to be `@send`. The compiler verifies the graph at build time — runtime surprises (audio glitches, deadlocks, sharing-violations) get caught as type errors.

## Stream runtime = task scheduler

There is no separate "async runtime" alongside the stream graph executor. They're the same thing.

- Each `stage` in a stream graph is a task.
- Stream channels (`|>` between stages) are the channel system above.
- Adjacent stages with compatible effects can be **fused** by the compiler into a single task — one suspension point per fused group, fewer context switches, better SIMD usage.
- Backpressure propagates through the graph automatically.
- `@realtime` graph segments get pinned to real-time-capable threads (audio worklet, low-latency pool).

Audio DSP, a UI event loop, an LLM token pipeline, and a worker queue all use the same primitives, the same scheduler, and the same effect-checking. One concurrency story for the whole language.
