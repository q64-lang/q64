# CLAUDE.md

Project-level conventions every agent working in this repo must follow.
Authoritative glossary lives in [`spec/README.md`](./spec/README.md) §"Vocabulary";
this file holds the rules that are easiest to get wrong.

## Naming and case

**Case carries meaning.** Pick the right form on purpose.

| Form | When to use |
|---|---|
| **Q64** | Brand wordmark. Headings, marketing, prose. The language and product family. |
| `q64` | The CLI tool. Monospace lowercase. Code blocks, command examples, shell output. |
| **Qube** | A *deployment artifact* qube — `type: "application"`, has `main`, runnable. Brand-style use in prose. |
| **qube** | A *library* qube — `type: "library"`, exports a surface, no `main`. Linked into other qubes. |
| **qubes** *(plural)* | Generic noun for either kind. What lives in the Continuum. |
| `qube` | The CLI tool. Monospace lowercase. Code blocks and command examples. |
| **Continuum** | The registry. Brand-style in prose. |
| `continuum.q64.dev` | The registry's UI host (humans browse here). |
| `qubes.q64.dev` | The registry's HTTP API host (the `qube` CLI hits this). |

**Examples that read correctly:**
- "Publish your qube to the Continuum with `qube publish`."
- "Deploy the Qube to qubepods."
- "Q64 is built on the WebAssembly Component Model."
- "Browse 1,200 qubes at continuum.q64.dev."

**Examples that are wrong:**
- ~~"Publish your Qube to the continuum."~~ (Qube ≠ library; continuum is a brand, capitalize)
- ~~"Run Q64 build."~~ (CLI is `q64`, monospace)
- ~~"qubes.q64.dev"~~ (old plural — the API host is `qubes.q64.dev`)

## Secrets, identity, and audience

This repo is **public**. Two classes of mistake have already cost a
history rewrite; never repeat them.

**1. Never commit identity or infrastructure values.** Not in docs, not
in examples, not in comments:

- credentials, API tokens, passwords (CI uses repo secrets);
- account identifiers and **account emails** (Cloudflare or otherwise);
- personal emails of any kind;
- provider resource ids — D1 database ids, KV namespace ids, zone ids
  (the pattern is `wrangler.example.jsonc` committed with placeholders,
  real `wrangler.jsonc` gitignored — see `continuum-api/`).

Use `<account-id>`-style placeholders plus "look it up with
`wrangler whoami`" instructions. Treat everything committed as
**permanently public** — a history rewrite is an emergency measure,
not an undo button.

**2. Write docs for their real audience.** Repo docs address
contributors and users. Contributors change things **by PR**; they
never deploy and hold no infrastructure access. Operator-only runbooks
(how q64.dev itself ships, account setup, console steps) do not belong
in this repo — keep them in the maintainers' private notes. If a doc
says "you" and the reader can't actually do the action, the doc is
addressed wrong.

## Continuum architecture (top-level layout)

- [`continuum/`](./continuum) — UI Worker. Deployed as `q64-continuum`. Route `continuum.q64.dev`.
- [`continuum-api/`](./continuum-api) — JSON API Worker. Deployed as `q64-continuum-api`. Route `qubes.q64.dev`. Owns D1 `q64-continuum` (metadata), R2 `q64-continuum-archives` (archives), KV (caches).

The `q64-` prefix on deploy names groups everything under the Q64 project in
the Cloudflare account; the local folder + package names stay short.
- [`web/`](./web) — `q64.dev` site (docs, landing). Separate concern from the registry.

The two Continuum Workers talk via a service binding, not the public network.

## Archive format

Qubes ship as `.zip` (DEFLATE), **not** tar.gz. See
[`spec/continuum-api.md`](./spec/continuum-api.md) §"Archive format" for layout
and content-addressing rules. The registry computes the canonical SHA-256.

## Spec pointers

The contracts that constrain implementation choices:

- [`spec/qube.json5.md`](./spec/qube.json5.md) — manifest schema
- [`spec/continuum-api.md`](./spec/continuum-api.md) — registry HTTP API
- [`spec/qube-cli.md`](./spec/qube-cli.md) — `qube` CLI surface
- [`spec/q64-cli.md`](./spec/q64-cli.md) — `q64` CLI surface
- [`spec/effects.md`](./spec/effects.md) — effect markers and propagation
- [`spec/env.md`](./spec/env.md) — capability model

When the spec and the code disagree, the spec is right and the code is a bug.
