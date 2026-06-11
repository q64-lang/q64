# stdlib/reactive → `q64.reactive`

Fine-grained reactive state. The primitives a UI (or any
changed-value consumer) is built on — the Stage-3 runtime of
[`spec/reactivity.md`](../../spec/reactivity.md), positioned against
the rest of the concurrency story in
[`spec/concurrency-model.md`](../../spec/concurrency-model.md).

> **Status: not yet implemented.**

## Surface (planned)

- **`State<T>`** — the writable reactive cell: `get()` returns the latest
  committed value, `set(v)` writes one. Rateless and write-driven — *not*
  the rate-typed dataflow `Signal<T, R>` from
  [`spec/streams.md`](../../spec/streams.md). (Renamed from `Signal<T>`;
  the `Signal` name is reserved for dataflow, per
  [`spec/concurrency-model.md` §D3](../../spec/concurrency-model.md).
  Precedent: TC39's `Signal.State`.)
- **`Memo<T>`** — a derived cell whose value is a pure function of other
  cells; recomputed lazily, cached until inputs change.
- **`Watch`** — subscribe to one or more cells and run a side effect when
  any change. (Named to avoid collision with the language's `@effect`
  capability tag.)
- **Dataflow interop** — a `State<T>` is **not** a stream; crossing into
  the dataflow world is explicit, per the closed bridge set in
  [`spec/concurrency-model.md` §D4](../../spec/concurrency-model.md):
  `State<T>.changes() -> Event<T>` outbound, and a sink stage (or event
  handler) calling `.set(v)` on the owning thread inbound.

One opinionated pick: pull-with-versioning, not push-with-graph-walking.
Reads sample; writes bump a version; `Memo` and `Watch` reconcile on next
read. This keeps the reactive layer scheduler-free (the one task scheduler
from [`spec/concurrency.md`](../../spec/concurrency.md) is the only
scheduler) and avoids the stale-closure / glitch hazards of naïve push
systems.
