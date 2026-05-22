# web

The q64.dev site: marketing landing, language docs, registry browser, and
the in-browser q64 playground.

> **Status: scaffolded.** Landing + docs shell + Cloudflare Worker
> (static assets) deploy are wired up. Registry UI and playground are
> not yet implemented.

## Stack

- **Astro 5** — site framework. Static-first with islands for interactive bits.
- **Starlight** — Astro's documentation theme. Runs the docs (sidebar,
  search, dark mode, prev/next navigation) and the splash landing page.
- **Cloudflare Worker + Static Assets** — deployment. One Worker
  (`q64-web`) serves the static build and handles hostname-level
  concerns. The registry API ([`../continuum`](../continuum)) and the
  MCP server ([`../mcp`](../mcp)) stay as separate Workers for blast
  radius — cross-Worker calls go through service bindings.

## Develop

```sh
pnpm install
pnpm dev              # http://localhost:4321 — Astro dev server
pnpm build            # outputs to ./dist
pnpm preview          # serve ./dist locally via Astro
pnpm wrangler dev     # run the actual Worker locally against ./dist
```

## Layout

```
web/
  astro.config.mjs            # Astro + Starlight + sitemap
  wrangler.jsonc              # Worker config (assets binding + future bindings)
  tsconfig.json               # Astro/site TS (excludes worker.ts)
  tsconfig.worker.json        # Worker TS (Cloudflare types)
  src/
    worker.ts                 # Worker entry — www->apex + ASSETS passthrough
    content.config.ts         # Starlight content collection
    content/docs/
      index.mdx               # splash landing (template: splash)
      welcome.md              # placeholder doc
    components/
      Footer.astro            # adds legal/contact line under Starlight footer
    styles/custom.css         # brand accents (violet)
    pages/                    # (planned) playground.astro, registry/
  public/
    _headers                  # response headers (security, cache-control)
    robots.txt
    brand/                    # logo marks, brand sheet, mascot, tokens
      hero.png                # (drop this in — used by the homepage)
```

The homepage references `/brand/hero.png`. Drop the hero artwork in
`public/brand/hero.png` and it picks up automatically; everything else
about the page renders fine without it.

## Deploy to Cloudflare Workers

Worker name is `q64-web` (matches `wrangler.jsonc` `name`). Two ways:

### Option 1 — Git integration via Workers Builds (recommended)

1. Cloudflare dashboard: **Workers & Pages** → **Create** → **Workers**
   → **Connect to Git** → pick `q64-lang/q64`.
2. Build settings:
   - **Root directory**: `web`
   - **Build command**: `pnpm install --frozen-lockfile && pnpm build`
   - **Deploy command**: `npx wrangler deploy` *(default)*
   - **Environment variables**: `NODE_VERSION=22`, `PNPM_VERSION=9.15.0`
3. After first deploy, attach the domains: **Workers → q64-web →
   Settings → Domains & Routes → Add → Custom Domain**, add `q64.dev`
   and `www.q64.dev`. Then uncomment the `routes` block in
   `wrangler.jsonc` so future deploys keep them attached.

The `src/worker.ts` handler intercepts every request (because
`assets.run_worker_first` is `/*`) and 301-redirects `www.q64.dev` to
the apex before delegating to the `ASSETS` binding. Replaces the old
Pages `_redirects` file.

### Option 2 — Direct `wrangler` deploy

```sh
pnpm install
pnpm deploy            # = astro build && wrangler deploy
```

First time on a machine: `pnpm wrangler login`. The Worker is created
on first deploy if it doesn't exist.

## Why one Worker for the site only

Folding the registry API and MCP server into this Worker would let one
bad deploy (e.g. a Starlight upgrade that fails at build time) take
out the API surface too. Keeping them as siblings means the deploy
units match the failure domains. Service bindings keep cross-Worker
calls cheap.

## Why in-monorepo

The playground (planned) depends on a specific wasm build of
[`../q64/`](../q64). A language change and its playground update need to
ship in one commit, and docs updates often follow CLI changes in the
same PR. Same-repo lockstep is cleaner than cross-repo coordination.

## Brand

[`public/brand/`](./public/brand) holds the logo marks, the brand sheet,
the color palette, and the mascot concept.
`public/brand/tokens.json5` is the machine-readable source of truth for
colors and naming. See [`public/brand/README.md`](./public/brand/README.md)
for the asset inventory and what's still missing.
