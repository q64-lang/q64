# q64-docs — docs.q64.dev

The q64 language documentation site. Astro + Starlight on a Cloudflare Worker
(`q64-docs`, route `docs.q64.dev`). Separate from the landing site
(`../web`, `q64-web`) so docs deploy on their own cadence.

## Content model

Three nav groups, two engines + one mirror:

| Group | Source | How |
| --- | --- | --- |
| **Guides** | hand-written | committed under `src/content/docs/guides/` |
| **Reference** | `q64 doc --json` → `doc.json` | **generated** by `scripts/gen-docs.mjs` |
| **Spec** | `../spec/*.md` | **mirrored** at build time |

Everything generated (`src/content/docs/reference/`, `src/content/docs/spec/`,
`public/llms.txt`, the copied theme/brand) is gitignored — the compiler and the
spec are the single sources of truth.

## Build

```sh
pnpm install
pnpm build      # prebuild runs scripts/gen-docs.mjs, then astro build
pnpm preview
pnpm deploy     # astro build && wrangler deploy
```

The generator does **not** build the compiler. It resolves the reference data
(`doc.json`) in order: `$DOC_JSON` → `$Q64_BIN doc --json` →
`../q64/zig-out/bin/q64 doc --json` → the committed `fixtures/doc.json`. CI
passes the `doc.json` released with the compiler via `$DOC_JSON`; local dev
falls back to the fixture so `pnpm dev` works offline.

## For agents

`docs.q64.dev/llms.txt` (and `/llms-full.txt`) is a machine-ingestible map of
the language reference, generated from the same `doc.json`.
