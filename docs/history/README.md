# History

The narrative documents that preceded `spec/`. These were a
running design conversation — RFCs, captured-conversation
snapshots, hand-drafted explainers — used to drive the formal
spec. They are kept here for context and provenance.

> **Read `spec/` first.** It's the authoritative source. These
> documents are archival; many of their concrete choices were
> revised on the way into the spec (see `MIGRATION.md` for the
> diff).

## Files

| File | What it is |
|---|---|
| [`design.md`](./design.md) | The original "design conversation" snapshot. The earliest articulation of what q64 is, the Wasm 3.0 bet, the dual-heap thesis, the streams-first principle. |
| [`memory.md`](./memory.md) | Narrative on regions, the dual heap, cross-region transfers, multi-memory architecture. Ported and tightened into [`../../spec/memory.md`](../../spec/memory.md). |
| [`concurrency.md`](./concurrency.md) | Narrative on scopes, tasks, channels, actors, cancellation. Ported into [`../../spec/concurrency.md`](../../spec/concurrency.md). |
| [`stdlib.md`](./stdlib.md) | Walkthrough of the q64 stdlib layout — math / anim / ai / net / audio. Source material for the per-module stdlib documentation that will live alongside the implementation. |
| [`example.md`](./example.md) | Hand-picked code samples illustrating type narrowing, the env capability surface, error handling, URL templates. Source for `../tutorials/`. |
| [`influences.md`](./influences.md) | The pile of languages that shaped q64 — what was borrowed (Lustre's synchronous tick, Zig's allocator threading, Swift's argument labels, F#'s pipe) and what was deliberately rejected. |
| [`MIGRATION.md`](./MIGRATION.md) | The TODO that drove the design → spec migration, annotated with every departure between the narrative and the landed spec. Useful when reading the narrative as a "but what actually shipped?" cross-reference. |

## Relationship to `spec/`

These documents are **discussion**; [`../../spec/`](../../spec/)
is the **answer key**. The spec deliberately departs from these
docs in several places — for example:

- `region rt: Arena<1.MB> { … }` block form (drafted as a
  `@scope`-style API in `memory.md`).
- `@shared struct …` and `@managed struct …` annotations
  (drafted as `shared_region world { … }` and
  `managed struct …` keyword forms).
- Single `transfer(to: …)` verb (drafted as three named ops
  `copy_to / pin_to / intern`).
- Sample rate as a const-generic type parameter on
  `Signal<T, R>` / `Stream<T, R>` (drafted rate-agnostic).
- Cross-thread signals via the distinct `SharedSignal<T, R>`
  type backed by `mem.shared` (drafted as sample-channel-hold).
- Capabilities as user-fittable faces (drafted as sealed types).

`MIGRATION.md` enumerates these departures per-spec.

## Why keep these around

Three reasons:

1. **Provenance.** When a spec decision looks arbitrary, the
   narrative often shows the alternatives that were considered
   and rejected.
2. **Examples.** The example code in `example.md` and `stdlib.md`
   is more idiomatic, more varied, and more honest about
   uncertainty than the spec's terse examples. Useful when
   writing tutorials.
3. **Vocabulary.** Some terms in these docs (the "Bet," the
   "stream runtime is the async runtime," "make invisible
   distinctions visible") survived into the design DNA of q64
   without being formalized anywhere in `spec/`.

When in doubt, prefer the spec. When the spec is silent, these
documents indicate intent.
