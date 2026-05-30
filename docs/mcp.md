# MCP (Model Context Protocol)

q64 ships an MCP surface so AI agents can drive the toolchain and query the
Continuum without screen-scraping CLI output.

## Decision (2026-05-30): local-only for the open-source project

**The open-source q64 project ships an MCP server as a local stdio process
bundled with the toolchain. It does not run a hosted MCP.**

- The hosted Worker at `mcp.q64.dev` is **retired**. The `mcp/` folder (the
  Cloudflare Worker) is removed; there is no `mcp.q64.dev` deployment or custom
  domain owned by the OSS project.
- Agents that want registry data call the **public Continuum API**
  (`qubes.q64.dev`) directly — it is already a public HTTP surface, so a hosted
  MCP shim would only duplicate it.

### Why

- **Cost stays off the OSS project.** A hosted MCP is ~free while it only
  echoes constants, but the moment it offers the compile-shaped tools
  (`q64.compile`, `q64.show.*`) in hosted mode it must run sandboxed, ephemeral
  `q64` invocations per request — real CPU billing plus the security surface of
  executing submitted code. The open-source project should not carry that.
- **The valuable language tools are inherently local.** An agent writing q64
  already has the `q64`/`qube` binaries on the machine; a stdio server next to
  them needs no hosting, no sandbox, and no domain to keep alive.
- **Registry access is already public.** `continuum.*` would just wrap
  `continuum-api`, which agents can call directly.

### Where a hosted MCP lives instead

Any hosted/remote MCP is a **Qubepods (company) concern**, optionally offered
free as promotion. The company can choose to absorb that cost as customer
acquisition — that is a marketing decision, distinct from the OSS project
subsidizing infra. See the qubepods repo (`docs/mcp.md`). Keep it as a separate
public Worker; do **not** fold it into the token-authenticated tenant server.

## Transport & tool surface (local stdio)

| Audience | Transport | Where it runs |
|----------|-----------|---------------|
| A coding agent on a developer's machine | stdio | local, next to the `q64` binary |

The MCP server re-exposes existing contracts; it adds none of its own. Every
tool maps to either a CLI invocation or a public Continuum API call.

- **Language tools** (`q64.*`) — shell out to the local `q64` binary
  (`q64.show.types`, `q64.show.effects`, `q64.compile`, `q64.fmt`, …).
- **Package tools** (`qube.*`) — shell out to the local `qube` binary
  (`qube.validate_manifest`, `qube.resolve`, `qube.audit`, `qube.outdated`).
- **Registry tools** (`continuum.*`) — call the public Continuum API
  (`continuum.search`, `continuum.qube_metadata`, `continuum.qube_version`).

All tools are stdio-only and need no auth: language/package tools run against
the user's own machine, and registry reads hit a public API.

## Relationship to qubepods

qubepods runs its *own* MCP server (`apps/mcp-stage`) for project-scoped,
token-authenticated operations against deployed qubes. That server and the q64
MCP share the MCP framing but serve different surfaces:

- **q64 MCP** — language toolchain + public registry. Local stdio. No auth.
- **qubepods MCP** — per-project control plane. Hosted. Project-token auth.

Don't merge them: the trust boundaries differ (anonymous local/public reads vs.
authenticated tenant control). A separate, optional **free public promo MCP**
may also live on the qubepods/company side (registry browsing, a capped "try
q64" playground) — again hosted by the company, not by the OSS project.
