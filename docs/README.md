# docs

Source for the q64 language reference and tutorials. Rendered by
[`../web/`](../web) using Astro + Starlight; the published version is hosted
at q64.dev.

> **Status: not yet implemented.** Content will move here from
> [`q64-lang/design`](https://github.com/q64-lang/design) as design
> decisions stabilize into reference material.

## Scope

- **Language reference** — types, regions, effects, concurrency, streams,
  the full surface area of the language.
- **Tutorials** — getting-started, audio DSP walkthrough, stream graphs,
  WebAssembly targets.
- **`q64` and `qube` CLI manuals** — subcommand reference.
- **`qube.json5` manifest reference** — every field, every effect declaration.

## Relationship to `q64-lang/design`

The `q64-lang/design` repo is the **discussion** space — RFCs, in-progress
proposals, captured-conversation snapshots. `docs/` is the **published
reference** — a single source of truth users link to. Material graduates
from `design` to `docs` once it stops moving.
