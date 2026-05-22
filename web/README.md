# web

The q64.dev site: marketing landing, language docs, registry browser, and
the in-browser q64 playground.

> **Status: scaffolded.** Landing + docs shell + Cloudflare Pages deploy
> are wired up. Registry UI and playground are not yet implemented.

## Stack

- **Astro 5** — site framework. Static-first with islands for interactive bits.
- **Starlight** — Astro's documentation theme. Runs the docs (sidebar,
  search, dark mode, prev/next navigation) and the splash landing page.
- **Cloudflare Pages** — deployment. Pairs with the
  [`../continuum`](../continuum) Workers backend on the same Cloudflare
  account.

## Develop

```sh
pnpm install
pnpm dev          # http://localhost:4321
pnpm build        # outputs to ./dist
pnpm preview      # serve ./dist locally
```

## Layout

```
web/
  astro.config.mjs            # Astro + Starlight + sitemap
  wrangler.jsonc              # CF Pages project + future bindings (R2/KV/D1)
  src/
    content.config.ts         # Starlight content collection
    content/docs/
      index.mdx               # splash landing (template: splash)
      welcome.md              # placeholder doc
    components/
      Footer.astro            # adds legal/contact line under Starlight footer
    styles/custom.css         # brand accents (violet)
    pages/                    # (planned) playground.astro, registry/
  public/
    _headers                  # CF Pages response headers
    _redirects                # www.q64.dev -> q64.dev (apex)
    robots.txt
    brand/                    # logo marks, brand sheet, mascot, tokens
      hero.png                # (drop this in — used by the homepage)
```

The homepage references `/brand/hero.png`. Drop the hero artwork in
`public/brand/hero.png` and it picks up automatically; everything else
about the page renders fine without it.

## Deploy to Cloudflare Pages

The site is a static Astro build, so Cloudflare Pages serves
`./dist/` directly. Two ways:

### Option 1 — Git integration (recommended)

1. In the Cloudflare dashboard: **Workers & Pages** → **Create** →
   **Pages** → connect this repo.
2. Build settings:
   - **Framework preset**: Astro
   - **Root directory**: `web`
   - **Build command**: `pnpm install --frozen-lockfile && pnpm build`
   - **Build output directory**: `dist`
   - **Environment variables**: `NODE_VERSION=22`
3. Under **Custom domains**, add `q64.dev` and `www.q64.dev`. The
   `_redirects` in this project forces `www` → apex.

### Option 2 — Direct `wrangler` deploy

```sh
pnpm build
pnpm dlx wrangler pages deploy ./dist --project-name=q64-web
```

First-time setup: `wrangler pages project create q64-web`.

If the build pipeline errors with *"you've run a Workers-specific
command in a Pages project"*, check the dashboard's **Deploy command**
field under *Settings → Builds & deployments* — leave it empty so
Cloudflare auto-runs `wrangler pages deploy` (which reads
`pages_build_output_dir` from `wrangler.jsonc`).

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
