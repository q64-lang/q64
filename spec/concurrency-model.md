# Concurrency & reactivity — the consolidated model

q64 has four surfaces that all describe *work and values over time*:
imperative tasks ([`concurrency.md`](./concurrency.md)), message-passing
actors (same file), dataflow graphs ([`streams.md`](./streams.md)), and
reactive UI state ([`reactivity.md`](./reactivity.md)). Each earned its
place separately; this chapter is the umbrella that fixes how they relate.
It owns the **relationships and the naming rules** — each primitive's
detailed semantics stay in its owning spec.

> **Status: normative.** The decisions below (D1–D4) bind the other
> specs and the stdlib. Where an older file says otherwise, this file
> wins and the older file is a bug (tracked in §"Edits applied to other
> specs").

## The three questions this chapter answers

1. **Which primitive do I reach for?** Tasks, channels, actors, stages,
   graphs, reactive state — the overlap is real (an actor is expressible
   with channels; a UI counter is expressible as a graph). §D2 gives the
   decision table and the ownership rules.
2. **One runtime or four?** One. §D1 states the global invariant and the
   lowering table.
3. **What is a `Signal`?** Until now, two unrelated things:
   [`streams.md`](./streams.md)'s rate-typed continuous dataflow type
   `Signal<T, R>`, and the planned Stage-3 fine-grained reactive
   primitive `Signal<T>` in `q64.reactive`
   ([`reactivity.md`](./reactivity.md) §"Recommended model + staged
   path"). §D3 resolves the collision by renaming the reactive
   primitive to `State<T>`.

## The layer map

```
   imperative            messaging              dataflow                reactive
   ──────────            ─────────              ────────                ────────
   scope / spawn         actor / handle         @stage / graph / |>     state / @state
   select / ctx          tell / ask             Signal<T, R>            State<T> / Memo<T>
   Handle<T>             twin (remote actor)    Event<T> / Stream<T, R> Watch
        │                      │                      │                      │
        └──────────────────────┴──────────┬───────────┴──────────────────────┘
                                          ▼
                     tasks + channels + ONE scheduler
              (concurrency.md; v0: single-threaded cooperative
               scheduler — stack-switching is unavailable on the
               floor, see memory.md §"Concurrency platform audit")
```

Every box in the top row is a *surface*: a checked, sugared way of
arranging the same substrate. None of them brings its own runtime.

## Vocabulary

Consolidated from the owning specs; the per-file tables remain
authoritative for detail, this one for *which word means which layer*.

| Word               | Layer      | Meaning                                                                  | Owning spec |
|--------------------|------------|--------------------------------------------------------------------------|-------------|
| **task**           | substrate  | A unit of work on its own coroutine stack. The only unit of execution.   | `concurrency.md` |
| **channel**        | substrate  | Ownership-transferring queue between tasks.                              | `concurrency.md` |
| **scope**          | imperative | Structured-concurrency block that owns tasks and an arena.               | `concurrency.md` |
| **actor**          | messaging  | A task with private state and a typed inbox. The *local* serialized-state form. | `concurrency.md` |
| **twin**           | messaging  | An actor whose task runs remotely (Durable-Object-backed), addressed by a `@state` scope. The *distributed* form of the same shape. | `reactivity.md` (addressing), `rpc.md` (wire) |
| **stage**          | dataflow   | An `@stage`-annotated function; a node in a graph; runs as a task.       | `streams.md` |
| **graph**          | dataflow   | A declared topology of stages. `start()` → `Handle<Out>`.                | `streams.md` |
| **`Signal<T, R>`** | dataflow   | *Continuous, rate-typed* value: `Time → T` at rate `R`. **The name `Signal` is reserved for this type** (§D3). | `streams.md` |
| **`Event<T>`**     | dataflow   | Discrete occurrences. Sparse; no rate.                                   | `streams.md` |
| **`Stream<T, R>`** | dataflow   | Ordered sequence with completion.                                        | `streams.md` |
| **`SharedSignal<T, R>`** | dataflow | Cross-thread single-writer continuous value (SAB-backed). Dataflow semantics, hence the `Signal` name. | `streams.md` |
| **tick**           | dataflow   | One logical instant of a clocked graph. Driven by a rate.                | `streams.md` |
| **`state` / `@state`** | reactive | The declaration surface for reactive state; `@` marks the boundary-crossing (synced/persisted) form. | `reactivity.md` |
| **`State<T>`**     | reactive   | The runtime fine-grained reactive cell (Stage 3). Rateless; write-driven. *Renamed from `Signal<T>`* (§D3). | `stdlib/reactive` |
| **`Memo<T>`**      | reactive   | Derived cell: a pure function of other cells, cached by version.         | `stdlib/reactive` |
| **`Watch`**        | reactive   | Subscription that runs a side effect when watched cells change.          | `stdlib/reactive` |
| **batch**          | reactive   | One commit of pending reactive writes (per handler / per frame). **Not** a tick: nothing clocks it. | `reactivity.md` |

## D1 — One substrate (normative)

`concurrency.md` §"Stream runtime = task scheduler" and `streams.md`
already state pairwise that graphs and tasks share a scheduler. This
decision makes the invariant global, **including the reactive layer**:

> **There is exactly one scheduler.** Every surface lowers to tasks and
> channels on it. No surface may introduce a second event loop, a
> reactive micro-task queue, or a private thread.

The reactive layer satisfies this without a scheduler of its own:
a `State<T>` write is a plain memory write plus a version bump on the
owning thread; `Memo` re-computation and `Watch` effects run as ordinary
work **on the task that commits the batch** (the event handler's task,
per `reactivity.md` §"Cross-cutting": batch per event/frame). There is
no "reactive runtime" to schedule against — reconciliation is
pull-with-versioning (`stdlib/reactive`), so it happens inside reads,
on whichever task reads.

### Lowering table

| Surface construct        | Lowers to                                                                        |
|--------------------------|-----------------------------------------------------------------------------------|
| `spawn { … }`            | a task                                                                            |
| `actor` + `tell`/`ask`   | a task + a `Backpressure` inbox channel + a `select` loop (`concurrency.md` §Actors, desugared form) |
| twin (`@state(scope)`)   | the same actor shape, hosted remotely; messages travel the gate socket per `rpc.md`; subscribers receive diffs |
| `@stage` fn              | a task (or a fused group sharing one task, per `@fuse`)                            |
| `a \|> b` (graph edge)   | a `channel<T>(…)` whose policy is fixed by the LHS dataflow type (`streams.md` §"Stream runtime = task scheduler") |
| `Signal<T, R>` edge      | `LatestValue` channel                                                              |
| `Event<T>` edge          | `RingBuffer` channel                                                               |
| `Stream<T, R>` edge      | `Backpressure` channel                                                             |
| `state x = v` (static deps)  | a wasm cell + compiler-emitted mutation bindings (Stage 2; no runtime cell)    |
| `state x = v` (dynamic deps) | a `State<T>` cell + version (Stage 3)                                         |
| `Memo<T>` / `Watch`      | version-checked thunks run on the committing/reading task                          |
| `@state x = v`           | `state x = env.kv("x", v)` — a subscription to a twin; remote diffs arrive as mutation ops (`qview-protocol.md`) |

Consequences:

- Effects compose across layers with no special cases: a `Watch` body is
  ordinary code on an ordinary task, so `@no_alloc` / `@realtime` /
  `@cancel` checking applies to it exactly as to any function.
- Panic propagation is uniform: a panicking `Watch` unwinds the task
  that committed the batch, and the enclosing `scope … catch` sees it
  like any other panic.

## D2 — Four surfaces, four jobs (normative)

Each surface exists for a distinct job. The overlaps are intentional —
the higher surfaces are *checked sugar* over the lower ones — so the
rule is **ownership, not prohibition**: you *may* hand-roll an actor
from channels, but the spec'd, diagnostic-checked path for each job is
the one in this table.

| You need…                                                            | Reach for                          | Not                                |
|----------------------------------------------------------------------|------------------------------------|-------------------------------------|
| Run several things at once; join or race their results               | `scope` / `spawn` / `select`       | an actor per computation            |
| Move values between running tasks                                    | `channel<T>(…)`                    | shared state + locks                |
| Serialize mutations to one piece of state with many writers          | `actor`                            | `Shared<T, Mutex>` (opt-in escape hatch, `memory.md`) |
| The same, shared across devices / users / the network                | a twin via `@state(scope)`         | hand-rolled sockets + an actor      |
| Transform values flowing at a rate (audio, tokens, video, sensors)   | `@stage` / `graph` / `\|>`         | actor pipelines, channel spaghetti  |
| UI state → pixels                                                    | `state` / `@state` + QView         | a 60 Hz stream graph                |
| Cross-thread fan-out of a continuous value (meter, envelope)         | `SharedSignal<T, R>`               | a `State<T>` behind a lock          |

Two ownership rules that previously lived nowhere:

### QView is owned by the reactive layer

A QView UI renders from `state` / `@state` through the retained
mutation protocol ([`qview-protocol.md`](./qview-protocol.md)):
**signals-decide-what, surgical-mutation-applies-how**, per the staged
path in `reactivity.md`. Stream graphs do **not** drive QView — a UI is
not a clocked pipeline, and re-rendering at a rate is exactly the
immediate-mode model `reactivity.md` rejects. The "Reactive UI counter"
example in `streams.md` demonstrates generic dataflow composition, not
the QView path; it is annotated accordingly.

Dataflow still *feeds* UIs — an LLM token stream, an audio meter — but
it crosses into the reactive layer through the bridges in §Bridges
(typically: a sink stage writes a `State<T>` on the UI thread), and the
reactive layer applies the mutations.

### A twin is an actor

`reactivity.md` §"State scopes & twins" already decided this
("a twin = an actor backed by a Durable Object"); it is now normative
across the specs. The actor's invariants — isolation, serial message
processing, typed inbox — are exactly the twin's consistency story (the
DO's single thread is the serialization boundary). The difference is
placement and addressing, not shape:

| Property        | `actor` (local)                       | twin (remote)                                            |
|-----------------|----------------------------------------|----------------------------------------------------------|
| Task placement  | this Wasm instance's scheduler         | a Durable Object                                         |
| Address         | the handle from `X.spawn()`            | the `@state` scope (`user` / `app` / `room r`) → DO id   |
| Message wire    | inbox channel                          | gate socket, `rpc.md` encoding                           |
| Lifetime        | the enclosing `scope`                  | the deployment (persisted)                               |
| Reply           | `ask(…) -> Future<T>`                  | `ask(…) -> Future<T>` (same surface; `@wire` effect)      |

A future `twin` declaration form (typed methods beyond `inc`; tracked
in [`todo.md`](../todo.md)) must desugar to `actor` + this table — it
may not introduce a third shape.

## D3 — The `Signal` name (normative)

The collision: `Signal<T, R>` (auto-prelude, `streams.md`) and the
planned `Signal<T>` in `q64.reactive` (`reactivity.md` Stage 3,
`stdlib/reactive/README.md`) named two semantically unrelated things:

|                | dataflow `Signal<T, R>`                          | reactive cell (Stage 3)                              |
|----------------|---------------------------------------------------|------------------------------------------------------|
| Clock          | rate `R`; advances by ticks                      | none; writes happen when they happen                 |
| Read           | `.current()` — defined at every tick             | `.get()` — latest committed version                  |
| Write          | produced by its upstream stage; no setter        | `.set(v)` from any code on the owning thread         |
| Propagation    | graph edges (channels), backpressure-aware       | dependents reconcile at next read / batch commit     |
| Identity       | an edge in a topology                            | a *place* (a spreadsheet cell)                       |
| Threading      | thread-local; `SharedSignal` for crossing        | thread-local; twins / channels for crossing          |

**Decision:** the name `Signal` is **reserved for the rate-typed
dataflow type**. The Stage-3 reactive primitives are renamed:

| Old (`stdlib/reactive` plan) | New          | Notes                                          |
|------------------------------|--------------|------------------------------------------------|
| `Signal<T>`                  | **`State<T>`** | The writable fine-grained cell.               |
| `Memo<T>`                    | `Memo<T>`    | Unchanged.                                     |
| `Watch`                      | `Watch`      | Unchanged (already named to dodge `@effect`).  |

Why `State<T>`:

1. **It closes the loop with the keyword.** `state x: i64 = 0` is the
   declaration surface (`reactivity.md`); `State<i64>` is the runtime
   cell it lowers to when its dependencies are dynamic (Stage 3). The
   keyword and the type tell one story — "`state` is backed by
   `State`" — instead of "`state` is backed by `Signal`, which is not
   the `Signal` you know."
2. **Precedent.** The TC39 Signals proposal names exactly this
   primitive `Signal.State` (and the derived one `Signal.Computed`).
   q64 keeps `State`, drops the namespace that collides.
3. **`SharedSignal<T, R>` keeps its name** — it has dataflow-Signal
   semantics (rate, `.current()`, single writer), so it sits on the
   correct side of the line.

**Naming rule (binding on specs and stdlib):** a *`Signal`* is always
rate-typed and continuous; a *`State`* is always rateless and
write-driven. No new type named `Signal` may be introduced outside
`streams.md`'s family, and no reactive cell may be called a signal in
normative text. (Prose discussing other ecosystems' "signals" — Solid,
TC39 — is fine when attributed.)

### Corollary: `EventStream<T>` is retired

`q64.event` planned an `EventStream<T>` alongside the language's
`Event<T>` — the same duplication one layer down. The language type
wins: `q64.event` exposes plain `Event<Tap>`, `Event<KeyPress>`, etc.,
and `Gesture<T>` is a state machine `Event<In> → Event<Out>`. No
stdlib type may shadow or wrap the three dataflow types under a new
name without adding semantics.

## D4 — Bridges between layers (normative, closed set)

Crossings between layers are explicit and few — same principle as
`streams.md` §"Why exactly four" conversions. The retired claim in
`stdlib/reactive` that "`Signal<T>` *is* a stream" is exactly the kind
of implicit crossing this forbids: a `State<T>` is **not** an
`Event<T>` / `Signal<T, R>` / `Stream<T, R>`, and does not flow through
`|>`.

| # | Crossing                  | Form                                                                 | Notes |
|---|---------------------------|----------------------------------------------------------------------|-------|
| 1 | task ↔ dataflow           | `g.start() -> Handle<Out>`, `g.output()`, `g.completion()`           | Already specified (`streams.md` §`Graph<Out>`). |
| 2 | task ↔ messaging          | `X.spawn()`, `tell` / `ask(…) -> Future<T>`                          | Already specified (`concurrency.md` §Actors). |
| 3 | reactive → dataflow       | `State<T>.changes() -> Event<T>`                                     | One event per committed batch in which the value changed. Mirrors `Signal<T, R>.changes()` by design. |
| 4 | dataflow → reactive       | a **sink stage** (or event-subscription handler) calls `.set(v)`     | Plain code, not an adapter. The write must happen on the cell's owning thread — a graph feeding UI state ends in a sink running on the UI task. |

Everything else composes from these plus the four `streams.md`
conversions (`changes` / `hold` / `fold` / `sample`). In particular:
dataflow → reactive → QView is the spec'd path for "pipeline output on
screen" (bridge 4, then the mutation protocol), and reactive → dataflow
(bridge 3) is how UI interactions enter a graph when a graph is
genuinely wanted (e.g. clicks gating an audio pipeline).

Threading restated for the reactive layer: `State<T>` is thread-local
and **not** `@send`. Cross-thread reactive sharing is, in order of
preference: a twin (cross-device/user), a `LatestValue` channel
mirroring the value (cross-thread, discrete), or a
`SharedSignal<T, R>` (cross-thread, continuous, real-time consumers).

## Example — one program, four surfaces

A chat screen: an LLM token pipeline (dataflow) streams into reactive
state, the conversation syncs through a twin, and the lifecycle glue is
a structured scope. Every layer crossing is one of the D4 bridges.

```q64
// ── Reactive layer: the screen owns state (reactivity.md) ──────────
screen Chat {
    state  draft:   str       = ""    // local cell; dynamic deps → State<str> (Stage 3)
    state  reply:   str       = ""    // the streamed completion accumulates here
    @state history: [Message] = []    // user twin — an actor, placed remotely (D2)

    draw {
        column {
            for m in history { bubble(m) }     // keyed reconciliation
            text(reply)
            text_input(bind: draft)
            button("Send")                     // fires the exported `on send` handler
        }
    }

    // Handlers are tasks on the one scheduler (D1): the suspensions
    // below yield to it — they do not block input dispatch.
    on send {
        history.push(Message.user(draft))      // command → twin → diff fan-out
        let prompt = draft
        draft = ""
        reply = ""

        scope {
            let g = complete.start(prompt)     // graph → task: Handle (bridge 1)

            for_each(g.output) |chunk| {       // sink loop on the cell's owning task:
                reply += chunk                 // bridge 4 — dataflow → reactive write
            }

            match g.completion().await() {
                Ok(())  -> {},
                Err(e)  -> log.warn("generation failed: {e}"),
            }
        } catch (e: Cancelled) {
            // screen torn down → scope cancelled → graph stopped; no orphans
        }
    }
}

// ── Dataflow layer: the rate-shaped work is a graph (streams.md) ───
@stage
fn detokenize(toks: Stream<Token<LlamaVocab>, 20.Hz>) -> Stream<str, 20.Hz> { … }

graph complete(prompt: str) -> Stream<str, 20.Hz> {
    llama_complete(prompt) |> detokenize       // edge = Backpressure channel (D1)
}

// Bridge 3 (reactive → dataflow), when a graph wants UI input:
// let edits: Event<str> = draft.changes()     // one event per committed batch
```

What the example pins down:

- **D1** — every box is the one scheduler's work: the graph's stages
  are tasks, `for_each(g.output)` suspends on a `Backpressure`
  channel, and `reply += chunk` is a memory write + version bump; the
  bubble list reconciles on the UI task's next batch. No second
  runtime appears.
- **D2** — each job sits on its owning surface: the rate-shaped token
  transform is a `graph`, the cross-device conversation is a twin
  (writes serialize at its remote actor), the screen is reactive
  `state`, and the lifecycle glue is a plain `scope`. The UI is *not*
  a 60 Hz render graph.
- **D3** — `reply` (a rateless `State<str>` under Stage 3) and
  `Stream<str, 20.Hz>` coexist with no name confusion.
- **D4** — the only crossings are the sanctioned bridges: the sink
  loop writing the cell inbound, `draft.changes()` outbound. Piping
  `reply |> anything` would be `STR040`; handing `reply` to a
  cross-thread channel would be `CONC052`.

## Diagnostics

This chapter introduces **no new diagnostic band**. The codes live with
their owning specs (`CONC*` in `concurrency.md`, `STR*` in
`streams.md`; reactive-layer codes will land with the `state` lowering
spec). Two existing codes are the enforcement points for this
chapter's rules:

- `STR040` (non-stage in pipeline) is what fires when a `State<T>` is
  piped with `|>` — it is not a dataflow type (D4).
- `CONC052` (non-`@send` payload in cross-thread channel) is what fires
  when a `State<T>` is smuggled across threads (D4, threading).

## Edits applied to other specs

Landed together with this chapter, so the corpus agrees:

- `reactivity.md` — Stage 3 primitives renamed to `State` / `Memo` /
  `Watch`; pointer here added.
- `qview-protocol.md` — Stage-3 mention renamed.
- `stdlib/reactive/README.md` — surface renamed; the "`Signal<T>` is a
  stream" interop claim replaced by bridges 3–4.
- `stdlib/README.md` — table row updated.
- `stdlib/event/README.md` — `EventStream<T>` retired in favor of
  `Event<T>` (D3 corollary).
- `streams.md` — note added reserving the `Signal` name; the
  "Reactive UI counter" example re-scoped as generic dataflow, not the
  QView path; related-specs link added.
- `concurrency.md` — related-specs link added.
- `spec/README.md` — contracts table row + vocabulary entries (`twin`,
  `Signal` vs `State`).

## Open items deferred

- **`State<T>` API details.** Equality semantics for change detection
  (structural vs version-only), transactions/batched writes as a
  user-visible API, and the `Memo` recomputation order guarantee land
  with the `stdlib/reactive` implementation, which is gated on the
  Stage-3 language lift (escaping closures + heap aggregates, per
  `closures.md` §deferred).
- **`twin` declaration form.** Typed twin methods beyond generated
  `inc`-style handlers; must desugar to `actor` per D2.
- **Backpressure for remote diffs.** What a twin does when a
  subscriber's diff channel falls behind (drop-oldest vs coalesce —
  `LatestValue` semantics per key is the working assumption).
- **Task-local reactive context.** Whether `Watch` registration should
  be implicit-by-read inside `draw` only (current plan) or available
  in any tracked scope; blocked on the Stage-2 dependency-analysis
  design.

## Related specs

- [`concurrency.md`](./concurrency.md) — the substrate: tasks,
  channels, scopes, select, actors, cancellation, panics.
- [`streams.md`](./streams.md) — the dataflow layer: `Signal<T, R>`,
  `Event<T>`, `Stream<T, R>`, stages, graphs, fusion, `SharedSignal`.
- [`reactivity.md`](./reactivity.md) — the reactive layer: `state` /
  `@state`, scopes & twins, the staged implementation path.
- [`qview-protocol.md`](./qview-protocol.md) — the mutation protocol
  the reactive layer drives.
- [`rpc.md`](./rpc.md) — the wire a twin's messages and diffs travel.
- [`effects.md`](./effects.md) — the markers that compose across all
  four surfaces unchanged (D1 consequence).
- [`memory.md`](./memory.md) — `@shared` / `Atomic<T>` /
  `Shared<T, P>`, the opt-in escape hatch the actor row in D2 points
  away from.
