# stdlib/event → `q64.event`

Input as streams. Pointer, gesture, keyboard, focus, and lifecycle events
lifted into typed q64 streams; usable by any consumer, not just UIs.

> **Status: not yet implemented.**

## Surface (planned)

- **Event payload types** — `Tap`, `Press`, `Drag`, `Pan`, `Pinch`,
  `KeyPress`, `TextChange`, `Scroll`, `FocusChange`, `Lifecycle` — carried
  by the language's `Event<T>` dataflow type
  ([`spec/streams.md`](../../spec/streams.md)). There is no separate
  `EventStream<T>` wrapper: `Event<Tap>` *is* the stream, and composes
  with the `q64.streams` operators (`map`, `filter`, `merge`, `throttle`,
  …). (Retired per
  [`spec/concurrency-model.md` §D3](../../spec/concurrency-model.md) —
  no stdlib type may shadow the dataflow types under a new name.)
- **`Gesture<T>`** — a state machine `Event<In> → Event<Out>` that emits a
  higher-level event (`Drag` → `Swipe`, `Press` + movement → `LongPress`,
  pairs of `Press` → `DoubleTap`).
- **Hit-testing protocol** — how a renderer reports which view received an
  input event; lives here (not in [`q64.view`](../view)) so non-view
  consumers (terminals, gamepads, server-side replay) can use the same
  vocabulary.

Kept separate from `q64.view` so a CLI, a server-side gesture replayer, or a
headless test harness can consume events without pulling in the view tree.
