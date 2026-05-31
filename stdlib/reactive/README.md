# stdlib/reactive → `q64.reactive`

State as streams. The reactive primitives a UI (or any value-over-time
consumer) is built on.

> **Status: not yet implemented.**

## Surface (planned)

- **`Signal<T>`** — a readable stream of a value over time, with a current
  sample (`get()` returns the latest, `set(v)` pushes a new one).
- **`Memo<T>`** — a derived signal whose value is a pure function of other
  signals; recomputed lazily, cached until inputs change.
- **`Watch`** — subscribe to one or more signals and run a side effect when
  any change. (Named to avoid collision with the language's `@effect`
  capability tag.)
- **Stream interop** — `Signal<T>` *is* a stream; reactive consumers feed
  directly into `q64.view` / `q64.event` pipelines without an adapter.

One opinionated pick: pull-with-versioning, not push-with-graph-walking.
Reads sample; writes bump a version; `Memo` and `Watch` reconcile on next
read. This matches q64's stream-first design and avoids the
stale-closure / glitch hazards of naïve push systems.
