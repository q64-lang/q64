# continuum

The qube registry server. Where all qubes exist.

`continuum` is the backend for `qube publish` / `qube add` / `qube install` —
it stores published qube tarballs, resolves dependencies, and surfaces each
qube's declared effects and capabilities.

> **Status: not yet implemented.** This folder will hold the registry
> implementation.

## Stack

- **Cloudflare Workers** — request handlers, dependency resolution.
- **Cloudflare R2** — qube tarball storage.
- **Cloudflare D1** — qube metadata, versions, ownership, capability index.
- **Cloudflare KV** — hot caches (latest-version lookups, search index).
- **TypeScript** — implementation language; matches the Workers runtime.

## Public source, private deploy

The registry code lives here under the monorepo's dual MIT/Apache-2.0 license.
Cloudflare account identifiers, R2/D1/KV namespace IDs, and abuse-prevention
thresholds live in a separate private repo (or `.env` outside this tree) and
are loaded at deploy time.

Precedent: crates.io, PyPI/warehouse, Hex.pm, and RubyGems are all open-source
registries with private deployment config. `continuum` follows the same model.

## Product URL

The user-facing domain is TBD — likely `qubes.q64.dev` or `registry.q64.dev`.
The repo name `continuum` is the thematic identity (the Q Continuum is where
all Q exist); the domain stays descriptive for everyday URLs.
