# docs

Source for the q64 language reference and tutorials. Rendered by
[`../web/`](../web) using Astro + Starlight; the published version
is hosted at q64.dev.

> **Status: scaffolded.** The formal spec lives in
> [`../spec/`](../spec); the historical design narrative lives in
> [`./history/`](./history). Tutorial and reference content for
> end users will accumulate here.

## Layout

| Folder / file                | What it is                                                                          |
|------------------------------|-------------------------------------------------------------------------------------|
| [`history/`](./history)      | The pre-spec design narrative — captured conversations, RFCs, the migration log.    |
| `reference/` *(forthcoming)* | User-facing reference for the language, distilled from `../spec/`.                  |
| `tutorials/` *(forthcoming)* | Step-by-step walkthroughs: getting started, audio DSP, stream graphs, Wasm targets. |
| `cli/` *(forthcoming)*       | `q64` and `qube` CLI manuals (subcommand reference).                                 |
| `manifest/` *(forthcoming)*  | `qube.json5` manifest reference (every field, every effect declaration).             |

## Relationship to `../spec/`

[`../spec/`](../spec) is the formal specification — the answer
key the compiler agrees with. `docs/` is the **published
reference and tutorial** for users — distilled, illustrated,
example-driven. Material moves from `spec/` into `docs/` once it
needs to be presented to a non-spec-reading audience.

## Relationship to `./history/`

[`./history/`](./history) is the **archive** of the documents
that preceded the spec — the design conversation, the RFCs, the
narrative explainers, and the migration log that tracks every
departure between narrative and spec. Useful for provenance and
for code samples; not the source of truth.
