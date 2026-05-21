# mcp

The q64 MCP (Model Context Protocol) server. Exposes the q64
toolchain to AI agents as a set of MCP tools.

> **Status: not yet implemented.**

## Why this folder exists

q64's stdlib already includes `q64.ai` for in-program LLM / vocab /
model work. The MCP server is the *complement*: it exposes q64 itself
(the language, the toolchain, the registry) to agents that are writing
or analyzing q64 code from the outside. AI coding agents can:

- Ask for the inferred type of an expression without compiling
  themselves (`q64.show.types`).
- Audit a candidate dependency before suggesting `qube add`
  (`qube.audit`).
- Validate a draft manifest before writing it to disk
  (`qube.validate_manifest`).
- Get diagnostics for a snippet they're about to propose
  (`q64.compile`).

## Stack

- **TypeScript on Bun** — same runtime as [`../continuum`](../continuum),
  so deployment infra and tooling are shared.
- Talks to local `q64` / `qube` binaries via subprocess when
  available, and to the production registry via HTTPS when not.
- MCP transport: stdio (for local agents) and SSE / streamable HTTP
  (for hosted deployments).

## Planned tools

Names are sketches; final tool names land with the implementation.

### From `q64`

| Tool                       | Backed by                          |
|----------------------------|------------------------------------|
| `q64.show.types`           | `q64 show types --diagnostics json` |
| `q64.show.effects`         | `q64 show effects --diagnostics json` |
| `q64.show.regions`         | `q64 show regions --diagnostics json` |
| `q64.show.graph`           | `q64 show graph --diagnostics json` |
| `q64.show.layout`          | `q64 show layout --diagnostics json` |
| `q64.compile`              | `q64 build` on a snippet; returns the diagnostic envelope and (optionally) the emitted wasm |
| `q64.fmt`                  | `q64 fmt --stdout`                 |

### From `qube`

| Tool                       | Backed by                          |
|----------------------------|------------------------------------|
| `qube.validate_manifest`   | Local JSON Schema validation; falls back to `POST /v1/validate` |
| `qube.resolve`             | `qube install --dry-run`           |
| `qube.audit`               | `qube audit` / `/v1/qubes/{name}/{version}/effects` |
| `qube.outdated`            | `qube outdated`                    |

### From `continuum`

| Tool                       | Backed by                          |
|----------------------------|------------------------------------|
| `continuum.search`         | `GET /v1/search`                   |
| `continuum.qube_metadata`  | `GET /v1/qubes/{name}`             |
| `continuum.qube_version`   | `GET /v1/qubes/{name}/{version}`   |

## Deployment

Two modes:

- **Local mode** — a developer runs `mcp` next to their `qube`
  workspace. Tools that need a compile shell out to the local `q64`.
- **Hosted mode** — `mcp` runs as a stateless service (Cloudflare
  Workers, alongside `continuum`). The compile-shaped tools spin up
  ephemeral q64 invocations in a sandboxed worker.

## Relationship to the spec contracts

The MCP server is a *consumer* of every contract under [`../spec/`](../spec):

- It validates inputs against [`qube.json5.schema.json`](../spec/qube.json5.schema.json).
- It parses subprocess output as [`diagnostics.md`](../spec/diagnostics.md) envelopes.
- It targets the [`q64-cli.md`](../spec/q64-cli.md) and
  [`qube-cli.md`](../spec/qube-cli.md) flag tables.
- It calls the [`continuum-api.md`](../spec/continuum-api.md)
  endpoints with bearer-token auth in hosted mode.

That's deliberate: the MCP server adds no new contracts. It is a
thin shim that re-exposes the same shapes as MCP tools, so adding
new toolchain capability is just "add a tool here that wraps the
existing CLI flag or HTTP endpoint."
