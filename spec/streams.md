# Streams, Signals, Events

The dataflow core of q64. Three first-class temporal types
(`Signal<T, R>`, `Event<T>`, `Stream<T, R>`), the `@stage` and
`graph` declarations that compose them, the `|>` pipe operator,
the `pre()` one-tick delay for feedback, the four canonical
conversions, opt-in fusion via `@fuse`, and the dedicated
`SharedSignal<T, R>` for low-latency cross-thread sharing.

The stream runtime *is* the task scheduler from
[`concurrency.md`](./concurrency.md); stages are tasks, the `|>`
is a channel, and `@realtime` graphs pin to real-time-capable
Wasm threads.

## Design goals

1. **One dataflow vocabulary for the whole language.** Audio, MIDI,
   AI tokens, video, IMU, UI clicks, file reads, network sockets —
   all instances of typed dataflow. No "AsyncIterator for LLMs,
   AudioBus for samples, EventEmitter for UI" trichotomy.
2. **Make invisible distinctions visible.** Continuous vs. discrete
   vs. terminating gets three types. Sample rate at the type level.
   Cross-thread sharing has a distinct type. Wrong wiring is a
   compile error.
3. **Synchronous-time semantics.** Within a logical tick, all
   simultaneous changes are coherent. Feedback cycles require
   explicit `pre()`. Inspired by Lustre / Lucid Synchrone;
   applicable to audio, control, simulation, UI.
4. **The compiler sees the graph.** `@stage`-annotated functions
   and `graph` declarations are static enough for fusion analysis,
   topology inspection, latency bounds, resource analysis.
5. **One runtime, one scheduler.** Stream graphs and async tasks
   share the same scheduler. No separate "reactive runtime"
   alongside the async runtime.

## Vocabulary

| Word              | Meaning                                                                          |
|-------------------|----------------------------------------------------------------------------------|
| **tick**          | One logical instant. Within a tick, simultaneous values are coherent.            |
| **rate**          | The frequency at which a `Signal` or `Stream` advances. A type parameter.        |
| **stage**         | An `@stage`-annotated function. Consumes dataflow types; produces dataflow types.|
| **graph**         | A `graph`-declared topology. First-class value; `.start(env)` / `.stop()`.       |
| **fusion**        | Compile-time merging of adjacent `@fuse` stages into a single task.              |
| **feedback**      | A cycle in the graph; broken by `pre()` (one-tick delay).                        |

## The three dataflow types

| Type              | What it is                                | Has `.current()` | Terminates | Carries rate |
|-------------------|-------------------------------------------|------------------|------------|--------------|
| `Signal<T, R>`    | Continuous: `Time → T`                    | yes              | no         | yes          |
| `Event<T>`        | Discrete: `[(Time, T)]`                   | no               | no         | no (sparse)  |
| `Stream<T, R>`    | Ordered sequence with completion          | no               | yes        | yes          |

### `Signal<T, R>` — continuous

Always has a value at every tick. Examples: audio PCM, IMU
readings, a UI element's current position, a fixed clock.

```q64
let mic:     Signal<PCM<f32>, 48.kHz>
let imu:     Signal<Vec3<f32, m/s²>, 1.kHz>
let clock:   Signal<Seconds, 60.Hz>
```

A `Signal<T, R>` always has a `.current() -> T` operation: it has
a value right now, by construction. Subscribing to a signal mid-
stream sees the current value immediately, not the next tick's.

### `Event<T>` — discrete

Exists at specific moments, not in between. Examples: MIDI
messages, UI clicks, network packets, GPS fixes.

```q64
let midi:    Event<MidiMessage>
let clicks:  Event<Point>
let gps:     Event<Vec2<f64, Degrees>>
```

`Event<T>` has no `.current()`. Subscribers see only events that
arrive *after* subscription. Events do not carry a rate parameter
because they are sparse — they happen when they happen.

### `Stream<T, R>` — ordered with completion

A typed ordered sequence that eventually completes (either
normally or with an error). Examples: HTTP response bodies, LLM
token streams, file reads, WebSocket messages on a connection
that may close.

```q64
let body:    Stream<Bytes, 1.MB.per.s>          // network rate
let tokens:  Stream<Token<LlamaVocab>, 20.Hz>   // tokens per second
let file:    Stream<Bytes, ad_hoc>              // file read rate is host-dependent
```

A `Stream<T, R>` carries a rate (often a coarse estimate or a
host-imposed limit). Completion is a first-class signal:
`stream.completion() -> Future<Result<(), Error>>`. The compiler
checks that downstream stages handle completion.

### Why three types instead of one

Stages declare which they want. Mixing them is a compile error
unless you cross via a conversion:

```q64
@stage
fn render(scene: Signal<Scene, 60.Hz>) -> Signal<Frame, 60.Hz> { … }

scope {
    let clicks: Event<Point> = ui.clicks()
    let g = graph my_app {
        let f = render(clicks)            // ← STR020: expected Signal, got Event
    }
}
```

Conversions are named and visible (see §"Conversions").

## Sample rate as a type parameter

A `Signal<T, R>` or `Stream<T, R>` carries its rate as a type
parameter (a const generic per
[`generics.md`](./generics.md)). The compiler treats two
different rates as different types:

```q64
let audio: Signal<PCM<f32>, 48.kHz> = mic.read()
let video: Signal<Frame, 60.Hz> = camera.read()

@stage
fn mix(a: Signal<f32, 48.kHz>, b: Signal<f32, 48.kHz>) -> Signal<f32, 48.kHz> { … }

let m = mix(audio, video)            // ← STR021: rate mismatch (48.kHz vs 60.Hz)
```

Cross-rate boundaries require an explicit conversion stage:

```q64
let audio_60 = audio |> resample(target: 60.Hz)        // Signal<PCM<f32>, 60.Hz>
let video_48 = video |> resample(target: 48.kHz)       // expensive, but explicit
```

### Rate-polymorphic stages

Stages can be rate-generic:

```q64
@stage
fn gain<const R: Hz>(input: Signal<f32, R>, k: f32) -> Signal<f32, R> {
    input.map(|x| x * k)
}

let pcm  = mic.read()                  // Signal<f32, 48.kHz>
let boosted = gain(pcm, 2.0)           // Signal<f32, 48.kHz> — R inferred
```

The compiler enforces that all `R`-parameterized signals in a
stage's signature share the same `R`. Mixing requires explicit
resampling.

### Rates as units

Rates compose with the units-of-measure system from
[`types.md`](./types.md):

- `48.kHz`, `60.Hz`, `1.MHz` — standard frequencies.
- `20.Hz` — discrete-step rates (LLM tokens, sensor polls).
- `1.MB.per.s` — bandwidth-style rates (network streams).
- `ad_hoc` — host-determined; no static rate analysis.

The rate is a compile-time value; runtime rate adaptation
(jitter, drift) is handled by the runtime, not encoded in the
type.

## `@stage` declaration

A stage is a function that consumes dataflow types and produces
dataflow types. Declared with `@stage` on a `fn`:

```q64
@stage
fn animate(
    clock: Signal<Seconds, 60.Hz>,
    clip:  AnimClip,
    skel:  Skeleton,
) -> Signal<[Mat4<f32>], 60.Hz> {
    clock.map(|t| pose_skeleton(skel, clip, t))
}
```

The annotation triggers stage-specific checks:

- At least one input must be a dataflow type
  (`Signal<T, R>` / `Event<T>` / `Stream<T, R>`).
- The return type must be a dataflow type, or a tuple of dataflow
  types, or `()` for sink stages.
- No direct recursion. A stage calling itself forms an
  unschedulable graph; `STR030`. Use `pre()` for explicit
  feedback.
- All `R`-parameterized signals in the signature must share `R`
  (`STR021`).
- Effects from [`effects.md`](./effects.md) propagate normally
  (`@realtime`, `@no_alloc`, `@pure`).

### Why annotation and not a `stage` keyword

The annotation pattern matches `@shared` (per `memory.md`),
`@managed`, `@derive`. Stages are functions with extra rules; the
annotation triggers the rules without adding a new top-level
keyword. The keyword would also force users to choose between
`fn` and `stage` upfront, whereas annotations let stage-ness be
a property of how the function is used.

### Sink stages

A stage with `-> ()` is a sink — it consumes a stream and does
something terminal (write to a device, send over the network):

```q64
@stage
fn play(audio: Signal<PCM<f32>, 48.kHz>) {           // -> () implied
    env.audio.write(audio)
}
```

A sink may not appear upstream of another stage in a graph
(`STR031`).

### Source stages

A stage with no dataflow inputs but a dataflow output is a source:

```q64
@stage
fn mic_input(env: Env) -> Signal<PCM<f32>, 48.kHz> {
    env.audio.input()
}
```

Sources read from the runtime (microphone, network, timer) into
the dataflow world. The compiler treats them as graph roots.

## `graph` declaration

A `graph` declares a topology of connected stages. First-class
value; can be started, stopped, inspected:

```q64
graph voice_pipeline(env: Env) {
    let pcm        = mic_input(env)                       // source
    let denoised   = pcm |> denoise(threshold: 0.1)
    let resampled  = denoised |> resample(target: 16.kHz)
    let tokens     = resampled |> whisper_asr(env.ai)
    let response   = tokens |> llama_complete(env.ai)
    let synthed    = response |> tts(env.ai)
    let _          = synthed |> play(env)                 // sink
}

scope {
    let h: Handle<()> = voice_pipeline.start(env)
    sleep(60.s)
    h.cancel()
}
```

Properties:

- A `graph` body is a sequence of `let` bindings; each binding's
  RHS is a single stage call or a `|>` pipeline.
- The compiler analyzes the whole topology: rate consistency,
  fusion candidates, effect propagation, resource bounds.
- `g.start(env)` returns a `Handle<()>` from `concurrency.md`. The
  graph runs until cancelled, panicked, or all sources are
  exhausted.
- `g.stop()` cancels every stage in the graph.
- `g.snapshot()` returns a static description (topology, fused
  groups, rates, effects) — used by `q64 show graph`.

Graphs nest:

```q64
graph subgraph(input: Signal<PCM<f32>, R>) -> Signal<PCM<f32>, R> {
    input |> denoise |> normalize
}

graph outer(env: Env) {
    let pcm = mic_input(env)
    let clean = pcm |> subgraph
    let _ = clean |> play(env)
}
```

A graph with parameters and a return type acts like a parameterized
sub-topology.

## The `|>` pipe operator

`|>` chains stages by passing the LHS as the first positional
argument of the RHS:

```q64
x |> f(y)                  // ≡ f(x, y)
x |> f(y) |> g(z)          // ≡ g(f(x, y), z)
```

F# / Elixir style. Reads top-to-bottom; the subject flows
through the operations. Works on any function, not just stages —
stages are the common case.

Within a `graph` body, `|>` is the canonical way to wire stages;
the compiler walks the desugared call tree to build the topology.
Outside a graph, `|>` is just syntactic sugar for nested calls.

A `|>` whose LHS is a dataflow type and whose RHS is not a stage
is `STR040` ("non-stage in pipeline") — the compiler caught a
likely typo (a regular `fn` rather than a `@stage`-annotated
one).

## `pre()` for feedback cycles

A graph with feedback (a stage's output feeding its own input)
needs a one-tick delay to break the cycle. Method on `Signal<T, R>`
and `Stream<T, R>`:

```q64
@stage
fn iir_filter(input: Signal<f32, R>) -> Signal<f32, R> {
    var state: Signal<f32, R> = 0.0
    state = input + 0.95 * state.pre()      // ← state.pre() = previous tick's state
    state
}
```

Semantics:

- `signal.pre()` returns the value the signal had on the previous
  tick.
- On tick 0 (or whenever the signal is first sampled), `pre()`
  returns the signal's declared initial value (`0.0` above) or
  `T.default()` if no initial is declared.
- `pre()` is the **only** way to form a feedback cycle in a graph.
  A cycle without `pre()` is `STR050` ("unbroken feedback cycle").
- `Event<T>.pre()` does not exist — events are pointwise and have
  no "previous tick" notion (`STR051`).

Inspired by Lustre / Lucid Synchrone, expressed in q64 method
syntax (consistent with `.map`, `.filter`, `.fold`).

## Conversions between Signal / Event / Stream

Four canonical conversions in the language. Everything else
(`map`, `filter`, `combine_latest`, `merge`, etc.) lives in
`q64.streams` as library code.

| Conversion                       | Direction                      | Meaning                                         |
|----------------------------------|--------------------------------|-------------------------------------------------|
| `signal.changes()`               | `Signal<T, R>` → `Event<T>`     | Emit an event whenever the signal's value changes. |
| `events.hold(initial: T)`        | `Event<T>` → `Signal<T, R>`    | Latch the last event value; rate inferred from context. |
| `events.fold(seed: U, f)`        | `Event<T>` → `Signal<U, R>`    | Accumulate event history with a folding function. |
| `signal.sample(events)`          | `Signal<T, R>`, `Event<U>` → `Event<T>` | Sample the signal at the times the events fire. |

```q64
let mouse_pos: Signal<Point, 60.Hz>      = ui.mouse()
let clicks:    Event<()>                  = ui.click()
let click_pts: Event<Point>               = mouse_pos.sample(clicks)
let trail:     Signal<[Point], 60.Hz>     = click_pts.fold([], |xs, p| xs.push(p))
let opened:    Event<bool>                = trail.changes().map(|xs| xs.len() > 5)
```

`hold` and `fold` introduce a rate (the rate of the signal they
produce) that is inferred from the surrounding graph's rate.
Within a `graph @rate(60.Hz)` … context, an `events.hold(0)` is
`Signal<i64, 60.Hz>`.

### Why exactly four

These are the conversions that **cross the temporal-type
boundary** in a non-trivial way (Signal ↔ Event, with rate-
introduction or sampling). Combinators that stay within one type
(`map`, `filter`, `merge` on two Events of the same shape,
`combine_latest` on two Signals at the same rate) compose
trivially from these four plus ordinary functions, and live in
`q64.streams`.

## Fusion via `@fuse`

Adjacent stages can be merged into a single task to reduce
context-switch overhead and improve SIMD usage. q64 fusion is
**opt-in**: stages are not fused unless the user marks them
`@fuse`.

```q64
@stage @fuse
fn denoise<const R: Hz>(input: Signal<f32, R>) -> Signal<f32, R> { … }

@stage @fuse
fn resample(input: Signal<f32, 48.kHz>) -> Signal<f32, 16.kHz> { … }

@stage              // not @fuse — task boundary here
fn whisper_asr<const R: Hz>(input: Signal<f32, R>, ai: AiEnv) -> Stream<Token<WhisperVocab>, 10.Hz> { … }

graph voice {
    let asr_in = mic_input(env) |> denoise |> resample      // fused into one task
    let tokens = asr_in |> whisper_asr                       // separate task
}
```

Effect of `@fuse`:

- The compiler may merge adjacent `@fuse` stages into a single
  task body (one suspension point per group).
- The compiler will refuse to fuse across an effect boundary
  (e.g., a `@realtime` stage and a `@no_realtime` stage cannot
  fuse), across a thread boundary, or across a stage with
  observable side effects between.
- A non-`@fuse` stage always forms a task boundary. Use this for
  scheduling, measurement, or debugging.

### Why opt-in

Automatic fusion conflicts with q64's "the compiler is your
answer key" principle: the user should know which stages are
tasks. `@fuse` makes the optimization explicit; `q64 show graph`
shows fused groups visually.

## Cross-thread signals: `SharedSignal<T, R>`

`Signal<T, R>` is by construction thread-local — it represents an
in-memory continuous value within one Wasm instance. To share a
signal across threads, q64 ships a distinct type backed by
`mem.shared` (per `memory.md`):

```q64
@shared
struct AudioState {
    level: SharedSignal<f32, 48.kHz>,
}

scope {
    let state = AudioState.new()

    // audio thread (writer):
    spawn @realtime {
        let pcm = mic_input(env)
        state.level = pcm |> rms_envelope          // continuously updates
    }

    // UI thread (readers, possibly many):
    spawn {
        loop {
            let v = state.level.current()           // SAB-backed atomic load
            draw_meter(v)
            sleep(16.ms)
        }
    }
}
```

Properties:

- `SharedSignal<T, R>` lives in `mem.shared` (per `memory.md`).
- Single writer; multiple readers. The writer is the stage
  producing the signal; readers call `.current()` from any thread.
- Latency: one tick + one atomic operation (~10 ns + tick period).
- Cost: SAB allocation + atomic op per tick. Use only where
  cross-thread visibility justifies it.
- `Signal<T, R>` does not implicitly convert to `SharedSignal<T, R>`;
  explicit `.shareable()` is required, and the result lives in
  `mem.shared`.

### Why a distinct type

The alternative — making `Signal<T, R>` `@send` when `T: @send` —
hides the cross-thread cost behind the type system. A distinct
type makes "this signal pays SAB overhead" visible at the
declaration. Matches q64's "make invisible distinctions visible"
principle. Also keeps the same-thread case zero-overhead.

### Cross-thread events and streams

`Event<T>` and `Stream<T, R>` go through the regular channel
mechanism from [`concurrency.md`](./concurrency.md). An event
stream sent across a thread boundary uses a `channel<T>(…)` with
a policy; the receiving side wraps the receiver in an event
stream.

## Error propagation

A stage has no `Result` return type at the graph boundary —
stages produce dataflow values, not `Result`-wrapped ones. A
fallible operation inside a stage body that surfaces an `Err`
**panics** with that `Err` value as the payload (any error type
fitting `Error` also fits `Panic` via the auto-derived bridge in
[`errors.md`](./errors.md)). The panic propagates per
[`concurrency.md`](./concurrency.md) §"Panics across tasks":
sibling stages in the same scope are cancelled; the graph's
enclosing `scope { … } catch { … }` (if any) intercepts it;
otherwise it re-panics at the scope's closing brace.

```q64
@stage
fn decode(input: Stream<Bytes, R>) -> Stream<Frame, R> {
    input.map(|b| match Frame.parse(b) {
        Ok(f)  -> f,
        Err(e) -> panic e,                      // explicit: unwind with the parse error
    })
}

scope {
    let g = graph audio { mic_input(env) |> decode |> play(env) }
    g.start(env).await()
} catch (e: Cancelled) {
    env.out("graph shut down cleanly")
} catch (e: Panic) {
    log.error("audio graph stopped: {e.fmt()}")
    bring_up_silence()
}
```

This is deliberate: q64 has one error-handling story (the
`errors.md` `Result<T, E>` + `panic` model), and graphs reuse it.
There is no second mechanism for "in-stream errors" (no
`Stream<Result<T, E>>` convention at the language level, though
user code can use it). Inside a stage body, fallible chains use
the same `try` propagation as any other function (the `Err` value
flows out of the stage only when an explicit `panic e` is
issued).

`Cancelled` (from `concurrency.md`'s cancellation model) is the
expected way for a graph to shut down cleanly — caught as its own
arm above so the application doesn't conflate cleanup with crash.

## Effects on stages

The effect markers from [`effects.md`](./effects.md) apply to
stages. The compiler enforces them across the graph:

| Marker         | Effect on stages                                                              |
|----------------|-------------------------------------------------------------------------------|
| `@realtime`    | Bounded execution; no alloc; pins the stage to a real-time-capable thread.    |
| `@no_alloc`    | The stage's body cannot allocate (linear or managed).                         |
| `@pure`        | No mutation, no observable side effects. Composes safely.                     |
| `@no_suspend`  | The stage cannot yield mid-body.                                              |
| `@send`        | The stage's outputs may cross thread boundaries.                              |
| `@cancel`      | The stage observes cancellation. Declared explicitly: a stage that wants to observe cancellation lists `ctx: Cancel` in its signature (acquiring `@cancel` per [`effects.md`](./effects.md)). Stages without `ctx` cannot call `ctx.cancelled()`; the graph still shuts them down at scope close. |

A `@realtime` graph (all stages `@realtime`) pins to a real-time-
capable thread (audio worklet on browser, low-latency pool on
native). Mixing `@realtime` and non-`@realtime` stages in one
graph is allowed; only the `@realtime` segment pins.

The compiler verifies effect compatibility across `|>`:

```q64
@stage
fn play(pcm: Signal<PCM<f32>, 48.kHz>) @realtime { … }

@stage
fn http_post(env: Env, url: Url, body: Bytes) { … }       // not @realtime

scope {
    let g = graph audio {
        let _ = mic_input(env) |> play |> http_post(env, url"…")   // ← STR060
    }
}
```

`STR060`: `@realtime` stage piped into non-`@realtime` stage.

## Stream runtime = task scheduler

Per [`concurrency.md`](./concurrency.md) §"Stream runtime = task
scheduler", there is no separate "reactive runtime" alongside the
task scheduler. They are the same. To restate the contract here:

- A stage is a task.
- A `|>` between stages is a `channel<T>(…)` from
  `concurrency.md` (with a policy derived from the dataflow
  type: `Backpressure` for `Stream`, `LatestValue` for `Signal`,
  `RingBuffer` for `Event` with capacity from history bound).
- Fused stages share a task body (one suspension point per fused
  group).
- A graph's `Handle<()>` (from `g.start(env)`) is the
  `Handle<T>` from `concurrency.md`.
- A graph's panic propagates via `scope { … } catch { … }`.
- A graph's cancellation observes the enclosing scope's `ctx`.

## Examples

### Voice agent (mic → ASR → LLM → TTS → speaker)

```q64
graph voice_agent(env: Env) {
    let pcm:      Signal<PCM<f32>, 48.kHz>   = mic_input(env)
    let denoised: Signal<PCM<f32>, 48.kHz>   = pcm |> denoise(threshold: 0.05)
    let prepped:  Signal<PCM<f32>, 16.kHz>   = denoised |> resample(target: 16.kHz)
    let tokens:   Stream<Token<WhisperVocab>, 20.Hz>
                                              = prepped |> whisper_asr(env.ai)
    let text:     Event<str>                  = tokens |> assemble_utterances()
    let response: Stream<Token<LlamaVocab>, 50.Hz>
                                              = text |> llama_complete(env.ai)
    let synth:    Signal<PCM<f32>, 24.kHz>    = response |> tts(env.ai)
    let out:      Signal<PCM<f32>, 48.kHz>    = synth |> resample(target: 48.kHz)
    let _                                      = out |> play(env)
}

scope {
    let h = voice_agent.start(env)
    select {
        _ = h.await()         -> {},
        _ = ctx.cancelled()   -> h.cancel(),
    }
} catch (e: Panic) {
    log.error("voice agent crashed: {e}")
}
```

Every Signal↔Stream↔Event crossing is explicit. Every rate change
is a named conversion. The compiler verifies the whole graph at
build time.

### Reactive UI counter

```q64
@stage
fn counter(clicks: Event<()>) -> Signal<i64, 60.Hz> {
    clicks.fold(0, |n, _| n + 1)
}

@stage @fuse
fn render(count: Signal<i64, 60.Hz>) -> Signal<Frame, 60.Hz> @realtime {
    count.map(|n| render_button(text: "Clicks: {n}"))
}

graph ui(env: Env) {
    let clicks = env.ui.button("Click me").clicks()
    let count  = counter(clicks)
    let frames = render(count)
    let _      = frames |> blit(env)
}
```

### Audio with IIR feedback

```q64
@stage
fn iir(input: Signal<f32, 48.kHz>, alpha: f32) -> Signal<f32, 48.kHz> {
    var y: Signal<f32, 48.kHz> = 0.0
    y = input + alpha * y.pre()              // one-tick feedback
    y
}

graph audio_path(env: Env) {
    let pcm    = mic_input(env)
    let smoothed = pcm |> iir(alpha: 0.9)
    let _      = smoothed |> play(env)
}
```

### Cross-thread visualization with SharedSignal

```q64
@shared
struct Meter {
    rms: SharedSignal<f32, 100.Hz>,
}

graph audio_engine(env: Env, meter: ref Meter) {
    let pcm = mic_input(env)
    meter.rms = pcm |> rms_envelope(window: 10.ms)        // writer (audio thread)
    let _    = pcm |> play(env)
}

scope {
    let meter = Meter.new()
    spawn { audio_engine.start(env, ref meter).await() }       // audio thread

    spawn {                                                     // UI thread (reader)
        loop {
            draw_vu_meter(meter.rms.current())
            sleep(16.ms)
        }
    }
}
```

The audio thread is `@realtime` (via `@realtime` on
`audio_engine`); the UI thread reads via `meter.rms.current()` at
its own pace. Latency from RMS update to UI read: one 48 kHz tick
plus one atomic load (~20 µs + 10 ns).

### LLM token pipeline with completion

```q64
graph chat(env: Env, prompt: str) -> Stream<str, 20.Hz> {
    let toks: Stream<Token<LlamaVocab>, 20.Hz> = llama_complete(env.ai, prompt)
    toks |> detokenize(env.ai)
}

scope {
    let g = chat.start(env, "explain monads")
    for_each(g.output) |chunk| {
        env.out.write(chunk)
    }
    match g.completion().await() {
        Ok(())  -> env.out.write("\n"),
        Err(e)  -> log.warn("generation failed: {e}"),
    }
}
```

`g.output` and `g.completion()` are the two queryable surfaces
of a graph that produces a `Stream<T, R>`.

## Diagnostic codes

All stream-and-graph diagnostics use the `STR` prefix. Numbers
stable, never reused. `STR070`-`STR099` reserved for expansion.

| Code     | Short message                                  | When                                                                                |
|----------|------------------------------------------------|-------------------------------------------------------------------------------------|
| `STR010` | `@stage` on function with no dataflow input    | An `@stage`-annotated `fn` has no `Signal` / `Event` / `Stream` parameter.          |
| `STR011` | `@stage` on function with non-dataflow return  | Return type isn't a dataflow type, a tuple of them, or `()`.                        |
| `STR012` | `@stage` body uses a forbidden feature         | E.g. capturing an outer mutable variable in a way the graph analyzer can't model.   |
| `STR020` | dataflow type mismatch in pipeline             | `Signal` piped into a `Stream` consumer, or similar.                                |
| `STR021` | rate mismatch                                  | Two signals at different rates in a stage signature without explicit resample.      |
| `STR022` | rate parameter must be `const`                 | A rate type parameter declared without `const`.                                     |
| `STR030` | direct stage recursion                         | A stage calls itself. Use `pre()` for feedback.                                     |
| `STR031` | sink stage upstream of another stage           | A `-> ()` stage appears in the middle of a pipeline.                                |
| `STR032` | source stage downstream of another stage       | A no-input source appears after a `|>`.                                              |
| `STR040` | non-stage in pipeline                          | `|>` whose RHS is a non-`@stage` function but whose LHS is a dataflow type.         |
| `STR050` | unbroken feedback cycle                        | A graph cycle with no `pre()` to break it.                                          |
| `STR051` | `pre()` on `Event<T>`                          | Events have no previous-tick notion.                                                |
| `STR052` | `pre()` outside a stage body                   | `pre()` is only meaningful inside graph evaluation.                                 |
| `STR060` | `@realtime` stage piped into non-`@realtime`   | Effect compatibility violation across `|>`.                                          |
| `STR061` | non-`@send` payload crossing thread boundary   | A stage's output is consumed on a different thread; payload isn't `@send`.          |
| `STR062` | `SharedSignal` with non-`@send` `T`            | The wrapped type must be `@send`.                                                    |
| `STR063` | multiple writers on `SharedSignal`             | A `SharedSignal<T, R>` may have at most one writer.                                  |

All codes use the envelope from [`diagnostics.md`](./diagnostics.md).

## Open items deferred

- **Hot-swap stages at runtime.** A graph today is static; runtime
  reconfiguration (replacing a stage in a running graph) is
  deferred. Use stop + start until the design lands.
- **Persistent stream state across restarts.** Checkpointing a
  graph's accumulator state to disk; resuming. Library-level for
  now (q64.streams.persist).
- **Distributed stages.** A `@stage` whose body runs on another
  machine. Out of scope for v0; the type system can model it
  later.
- **Graph composition operators beyond `|>`.** Parallel splits
  (`fork`), joins, fan-in / fan-out. Currently expressible by
  binding the upstream to a `let` and reusing; sugar deferred.
- **Latency bounds in the type system.** `Signal<T, R>` could
  carry a max-latency parameter; today latency is a property of
  the runtime, not the type. Tracked as a research direction.
- **`@stage` introspection at comptime.** Programmatically reading
  a stage's signature, inputs, outputs, effects. Useful for
  meta-programming; deferred until the comptime story lands more
  broadly.

## Related specs

- [`concurrency.md`](./concurrency.md) — the task scheduler that
  runs the graph; the channel mechanism that `|>` desugars to;
  the `scope { … } catch { … }` form for stage panics.
- [`effects.md`](./effects.md) — `@realtime`, `@no_alloc`,
  `@pure`, `@send`, `@cancel` on stages.
- [`memory.md`](./memory.md) — `@shared`, `Atomic<T>`,
  `SharedSignal<T, R>`'s `mem.shared` backing; the implicit
  `scope` arena that stage bodies allocate into.
- [`generics.md`](./generics.md) — const generics for the rate
  parameter `R`; type parameters on `Signal<T, R>` /
  `Event<T>` / `Stream<T, R>`.
- [`types.md`](./types.md) — units of measure (`48.kHz`, `60.Hz`,
  `1.MB.per.s`) used as rate values.
- [`faces.md`](./faces.md) — `Stage`, `Source`, `Sink`,
  `RateAware` as blessed faces (additions tracked in faces.md's
  "Open items deferred").
- [`errors.md`](./errors.md) — `Result<T, E>` and `panic` semantics
  that stage error propagation reuses.
- [`modules.md`](./modules.md) — `Signal`, `Event`, `Stream`,
  `SharedSignal`, `@stage`, `graph`, `pre`, `|>`, conversion
  primitives (`changes` / `hold` / `fold` / `sample`) are
  auto-prelude.
- [`diagnostics.md`](./diagnostics.md) — envelope format for the
  `STR*` codes.
