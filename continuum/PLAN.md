# Continuum — implementation plan

The Q64 package registry. Two Workers, shared model. Locked decisions
captured here; open decisions flagged. Authoritative naming rules live in
[`../CLAUDE.md`](../CLAUDE.md). API wire contract is
[`../spec/continuum-api.md`](../spec/continuum-api.md).

## Architecture

- **`continuum`** Worker (UI) → `continuum.q64.dev`.
- **`continuum-api`** Worker (JSON API) → `qubes.q64.dev`.
- `continuum` service-binds into `continuum-api` (no public hop).
- `web/` is the `q64.dev` site (Astro + Starlight) — docs/landing only, **not** part of the registry.

## Stack (locked)

### continuum-api
- Cloudflare Workers + Hono + TypeScript
- R2 `ARCHIVES` for .zip qubes, SHA-256 keyed under `archives/<sha>` / `pending/<sha>`
- D1 `DB` for metadata (SQLite, schema in `migrations/`)
- KV `CACHE` for hot lookups (popular, recent, category landing)
- zod for input validation

### continuum (UI)
- Workers + Hono + Hono JSX (TSX)
- htmx (~14 KB) for partial swaps (forms, lists, queue updates)
- Plain CSS + custom properties; no Tailwind, no PostCSS
- micromark for README rendering
- Lucide icons inlined as TSX SVG components
- Fonts: Fraunces (display, WONK axis), Inter (body, variable), JetBrains Mono (code) — ~280 KB self-hosted, immutable cache
- Service binding into API for server-rendered reads

## Auth model (locked)

- **Publish:** OAuth (GitHub + Google). CLI uses a long-lived token issued post-OAuth.
- **Download:** anonymous (npm/crates.io model).
- **Admin:** email allowlist via `ADMIN_EMAILS` env (comma-separated). Set per-deploy; no default ships in the example config.
- **Identity redundancy at approval time:** verified primary OAuth email **plus** one of {linked second OAuth provider, WebAuthn passkey, GitHub identity binding}.

## Approval model (locked)

- **Model B** + async content scanning.
- First-ever publish from a user → `pending_publishes` queue. Admin reviews the **user** (not the name).
- After approval, any new qube name + any version auto-publishes — no human in the CI/CD path.
- Async content scanning runs on every upload as a backstop (implementation deferred).
- All admin actions land in `audit_log`.

## Archive format (locked)

- `.zip` (DEFLATE), not tar.gz. See `spec/continuum-api.md` §Archive format.
- Layout: single root dir `<qube-name>-<version>/` with `/` → `-` in scoped names.
- 50 MB max unpacked v0.
- Server computes SHA-256 → canonical version id + R2 object key.

## Search (v0, locked)

- D1 SQLite FTS5 (BM25 ranking).
- Indexed fields: `name`, `description`, `keywords`, `categories`.
- Sort options: relevance, alpha, downloads, recent_downloads, recent_updates, new.
- `recent_downloads` = rolling 90-day window. Cron job rolls daily counter into D1 column at 03:00 UTC.
- KV slices for popular/recent/category landing pages.

## Categories vocabulary (v0 suggestion, not locked)

`audio` · `video` · `ai` · `network` · `web` · `dev-tools` · `system` · `data` · `crypto` · `parsing` · `ui` · `games`

Closed set. Add later via spec edit + migration.

## Naming (locked)

See [`../CLAUDE.md`](../CLAUDE.md) and `spec/README.md` §Vocabulary.

- Brand: **Q64**, **Qube**, **Continuum** (Capitalized).
- CLI: `q64`, `qube` (monospace lowercase).
- **qube** (library) vs **Qube** (artifact) vs **qubes** (generic plural).

## Open decisions

- [ ] **CLI OAuth flow:** device flow (`qube login` → URL + code) **or** browser-paste (UI → token → CLI config)?
- [ ] **Cloudflare zone confirmation** for `q64.dev` (needed before `wrangler deploy`).

## Deferred for v0+

- Effect indexing in registry (trust-and-verify v0; Wasm analyser later).
- Async content scanning execution path.
- Code highlighting in README rendering (Shiki later).
- README full-text indexing (FTS5 field, blows up index size).
- Vector / semantic search (Cloudflare Vectorize).
- Search autocomplete.
- Shared `continuum-types` package (steal from crates.io's `crates-io-api-client` pattern).

## Repo layout

```
q64/
├── CLAUDE.md                  ← naming + project-level rules
├── continuum/                 ← UI Worker
│   ├── package.json           (name: continuum)
│   ├── wrangler.jsonc         (route: continuum.q64.dev; binding API → continuum-api)
│   ├── PLAN.md                ← this file
│   └── src/{index.tsx, env.ts, dilbert.ts}
└── continuum-api/             ← JSON API Worker
    ├── package.json           (name: continuum-api)
    ├── wrangler.jsonc         (route: qubes.q64.dev; R2 ARCHIVES, D1 DB, KV CACHE)
    ├── migrations/0001_init.sql
    └── src/{index.ts, env.ts}
```

## Next concrete steps to ship v0

1. **(blocked on user)** Confirm CF zone + run `wrangler login`.
2. `wrangler r2 bucket create q64-continuum-archives`
3. `wrangler d1 create q64-continuum` → patch `continuum-api/wrangler.jsonc` with `database_id`
4. `wrangler kv namespace create q64-continuum-cache` → patch `id`
5. `wrangler d1 migrations apply q64-continuum --remote`
6. `pnpm install` in both project dirs
7. `wrangler deploy` from `continuum-api/`, then `continuum/`
8. Add custom-domain routes for `qubes.q64.dev` and `continuum.q64.dev`

## Spec edits queued

- ~~`spec/continuum-api.md:13`~~ (qubes.q64.dev → qubes.q64.dev) — applied in this build
- ~~`spec/qube-cli.md:120`~~ (qubes.q64.dev → qubes.q64.dev) — applied in this build
