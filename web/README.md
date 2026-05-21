# web

The q64.dev site: marketing landing, language docs, registry browser, and
the in-browser q64 playground.

> **Status: not yet implemented.**

## Stack

- **Astro** — site framework. Static-first with islands for interactive bits.
- **Starlight** — Astro's documentation theme. Runs the docs (sidebar,
  search, dark mode, prev/next navigation).
- **Cloudflare Pages** — deployment. Pairs with the
  [`../continuum`](../continuum) Workers backend on the same Cloudflare
  account.

## Layout (planned)

```
web/
  astro.config.mjs
  src/
    pages/
      index.astro              # marketing landing (not Starlight)
      playground.astro         # in-browser compiler
      registry/                # qube browser (talks to continuum)
    content/
      docs/                    # Starlight-managed; sourced from ../docs/
  public/
    q64.wasm                   # built from ../q64/ for the playground
```

## Why in-monorepo

The playground depends on a specific wasm build of [`../q64/`](../q64). A
language change and its playground update need to ship in one commit, and
docs updates often follow CLI changes in the same PR. Same-repo lockstep
is cleaner than cross-repo coordination.
