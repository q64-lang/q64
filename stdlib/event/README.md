# stdlib/event → `q64.event`

Input as streams. Pointer, gesture, keyboard, focus, and lifecycle events
lifted into typed q64 streams; usable by any consumer, not just UIs.

> **Status: not yet implemented.**

## Surface (planned)

- **Event types** — `Tap`, `Press`, `Drag`, `Pan`, `Pinch`, `KeyPress`,
  `TextChange`, `Scroll`, `FocusChange`, `Lifecycle`.
- **`EventStream<T>`** — a typed stream of events; composes with the
  existing stream operators (`map`, `filter`, `merge`, `throttle`, …).
- **`Gesture<T>`** — a state machine over an `EventStream` that emits a
  higher-level event (`Drag` → `Swipe`, `Press` + movement → `LongPress`,
  pairs of `Press` → `DoubleTap`).
- **Hit-testing protocol** — how a renderer reports which view received an
  input event; lives here (not in [`q64.view`](../view)) so non-view
  consumers (terminals, gamepads, server-side replay) can use the same
  vocabulary.

Kept separate from `q64.view` so a CLI, a server-side gesture replayer, or a
headless test harness can consume events without pulling in the view tree.
