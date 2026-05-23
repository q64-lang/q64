# continuum HTTP API

The wire contract between the [`qube`](./qube-cli.md) CLI and the
[`continuum`](../continuum) registry server. Read endpoints are
anonymous; write endpoints require a bearer token.

> **Status: draft (v0).** Endpoints, request/response shapes, and
> auth flow are subject to change while the language is pre-1.0.

## Conventions

- **Base URL:** the production registry. Default in `qube` is
  `https://qubes.q64.dev` (final URL TBD; see open items in the plan).
- **API prefix:** `/v1`. A breaking change moves the prefix to `/v2`
  and the previous version is kept available for one major-release
  grace period.
- **Content type:** request and response bodies are JSON unless
  otherwise noted. Archives are zip (`application/zip`, `.zip`).
- **Auth:** `Authorization: Bearer <token>` on write endpoints. Tokens
  are scoped (publish-only, owner-only, admin) and rate-limited.
- **Errors:** every non-2xx response body uses the same
  [diagnostic envelope](./diagnostics.md) `qube` already parses for
  compiler errors. HTTP status code complements but does not replace
  the envelope's `code` field.
- **Pagination:** `?page=<n>&limit=<n>` (1-indexed). Default limit 50,
  max 200. Responses include `next` / `prev` URL hints.
- **Caching:** read endpoints set `ETag` and respond to
  `If-None-Match`. Archive downloads also set `Cache-Control:
  immutable, max-age=31536000` because archives are content-addressed
  and never replaced.
- **Rate limits:** signalled via `X-RateLimit-Limit`,
  `X-RateLimit-Remaining`, `X-RateLimit-Reset` headers.

## Endpoints

### Read — qube metadata

```
GET /v1/qubes/{name}
```

Returns the qube's manifest digest, latest stable version, version
list, owners, and rendered README.

Path parameter `{name}` is URL-encoded (handles the `org/qube` form
as `org%2Fqube`).

```json
{
  "name": "audio-filters",
  "latest": "0.4.2",
  "owners": ["alice"],
  "description": "Real-time audio filters.",
  "repository": "https://github.com/...",
  "license": "MIT OR Apache-2.0",
  "downloads": 12034,
  "versions": [
    {
      "version": "0.4.2",
      "published_at": "2026-04-12T14:22:01Z",
      "yanked": false,
      "effects": ["@io"]
    },
    { "version": "0.4.1", "published_at": "...", "yanked": false, "effects": ["@io"] }
  ]
}
```

```
GET /v1/qubes/{name}/{version}
```

Returns the full manifest for a specific version plus its effect index,
declared targets, and dependency graph.

```
GET /v1/qubes/{name}/{version}/archive
```

Returns the `.zip` (immutable, content-addressed). The archive
contains the qube source tree rooted at the included `qube.json5`.

### Read — index (sparse, Cargo-style)

```
GET /v1/index/{prefix}/{name}
```

Returns a newline-delimited JSON list of every published version for
`{name}`, each line being a small record (version, dependencies,
yanked, effects digest). `qube`'s resolver fetches these efficiently
without paginating through versions.

Prefix sharding follows Cargo's: `qu/be/qube-name` for names ≥ 4
chars; shorter names use abbreviated shards (`1/x`, `2/xx`, `3/x/xxx`).

### Read — search and discovery

```
GET /v1/search?q=<query>&category=<cat>&effect=<marker>
```

Full-text and faceted search over name, description, keywords,
categories, and declared effects.

```
GET /v1/categories
GET /v1/popular?period=<24h|7d|30d|all>
GET /v1/recent
```

### Write — publish

```
POST /v1/qubes/{name}
Authorization: Bearer <token>
Content-Type: multipart/form-data

  manifest=<qube.json5 body>
  archive=<binary zip>
```

Server validates, in order:

1. Manifest matches [`qube.json5.schema.json`](./qube.json5.schema.json).
2. Version is not already published; name is available or owned by
   the token's subject.
3. **Archive checksum.** The server computes the SHA-256 of the
   uploaded archive and stores it as the version's canonical
   identifier. The manifest does *not* carry a checksum field; the
   archive is content-addressed by the server's computation, which
   is then returned to the client and recorded in `qube.lock` (per
   "Resolver protocol" below).
4. **Effect indexing.** The server runs the effect analyser (the
   same code path `qube audit` uses locally — see
   [`qube-cli.md`](./qube-cli.md) §"Publishing flow") on the
   uploaded archive, producing the qube's transitive effect set.
   The detected set is stored alongside the manifest and surfaced
   via `GET /v1/qubes/{name}/{version}/effects`.
5. **Effect cross-check.** The manifest's `effects.declared` must
   be a superset (after closure under implications) of the detected
   set. Drift returns `422 Unprocessable Entity` with a diagnostic
   envelope (`EFF130`) explaining which detected effect was missing
   from the declaration.
6. **Capability cross-check.** The manifest's `capabilities` must
   match the capability set derived from the effect index (per
   [`env.md`](./env.md) §"Capability disclosure"). Drift returns
   `422` with `ENV040`.

On success: `201 Created` with the new version's metadata, including
the indexed effect set and the computed SHA-256.

### Write — yank / unyank

```
DELETE /v1/qubes/{name}/{version}        # yank
POST   /v1/qubes/{name}/{version}/unyank # restore
```

Yanked versions are still resolvable for existing lockfiles but new
`qube add` calls skip them. Yanking is not deletion; the archive
remains downloadable for reproducibility.

### Write — owner management

```
POST   /v1/qubes/{name}/owners            { add: ["bob"] }
DELETE /v1/qubes/{name}/owners            { remove: ["bob"] }
GET    /v1/qubes/{name}/owners
```

The original publisher cannot be removed; ownership transfer is a
separate confirmed flow (see admin docs).

## Auth

```
POST /v1/auth/token
{
  "scopes": ["publish"],
  "description": "CI for example/voice-agent",
  "expires_in": 7776000
}
→ 201
{
  "token": "qube_pat_…",
  "id": "tok_abc123",
  "scopes": ["publish"],
  "expires_at": "..."
}
```

Tokens are PATs (personal access tokens); the registry never returns
the raw token again after creation. Token rotation and revocation
follow the same endpoint shape (`DELETE /v1/auth/token/{id}`).

## Resolver protocol

The expected dance for `qube install`:

1. For each direct dep in `qube.json5`, fetch
   `GET /v1/index/{shard}/{name}`.
2. Run resolution locally (pubgrub-style) producing a flat plan.
3. For each resolved `(name, version)`:
   - Fetch `GET /v1/qubes/{name}/{version}` for the full manifest.
   - Fetch `GET /v1/qubes/{name}/{version}/archive` and extract to
     `~/.qube/cache/sha256/<digest>/`.
4. Write `qube.lock` with name, version, source URL, sha256, and the
   effect index per dep.

`qube install --offline` skips steps 1, 3 and depends on `qube.lock`
+ a populated cache.

## Capability disclosure surface

`qube audit` calls:

```
GET /v1/qubes/{name}/{version}/effects
```

Response:

```json
{
  "declared":   ["@io", "@network"],
  "detected":   ["@io", "@network"],
  "transitive": ["@io", "@network"],
  "by_dependency": {
    "url-parser@1.2.0":   ["@pure"],
    "http-client@0.4.0":  ["@io", "@network"]
  }
}
```

Field semantics:

| Field            | Source                                                                       |
|------------------|------------------------------------------------------------------------------|
| `declared`       | The qube's manifest `effects.declared` (per [`qube.json5.md`](./qube.json5.md) §Effects). |
| `detected`       | The compiler-derived effect set from static analysis on this qube's `pub` surface. Matches `declared` after the publish-time cross-check (`EFF130`). |
| `transitive`     | The closure of `detected` over every dependency's `detected` set, per the implication graph in [`effects.md`](./effects.md). |
| `by_dependency`  | The contribution of each direct dependency to `transitive`. Map of `<name>@<version>` → effect list. |

The manifest's `effects.deny` field is **not** surfaced here —
denial is enforced locally at resolve time, not part of the
published metadata. (A dependency carrying a denied effect is
`EFF131`, raised by the resolver before any HTTP call.)

This is the data behind "what does this qube ultimately touch" —
shown in the registry UI on every qube detail page and in
`qube audit` output.

### RPC endpoint resolution

A qube that serves an RPC world (`rpc.export: true`, per
[`qube.json5.md` §RPC](./qube.json5.md)) registers a **served world** and an
**endpoint address** alongside its capability/effect metadata. A consumer's
`rpc.import` may name a qube instead of a literal `wrpc://…` URL; the
resolver maps the name to its endpoint here, the same way it resolves a
dependency version:

```
GET /v1/qubes/{name}/{version}/world
```

returns the synthesized WIT world the qube serves and its endpoint
address(es). Because importing a remote qube adds `@wire` to the consumer's
effect set (per [`effects.md`](./effects.md) and [`rpc.md`](./rpc.md)), the
remote dependency is disclosed in `qube audit` like any capability — the
`@wire` reach and the served world appear at `qube add` time. The endpoint
itself may be a qubepods deployment (per [`env.md`](./env.md)), whose
`wasi:http` endpoint doubles as the wRPC server.

## Schema validation endpoint (optional)

```
POST /v1/validate
Content-Type: application/json5

  <qube.json5 body>
```

Server validates against [`qube.json5.schema.json`](./qube.json5.schema.json)
and returns either `{ "ok": true }` or a diagnostic envelope describing
the schema violations. Useful for editors that don't want to bundle the
schema themselves.

## Archive format

- Container: a **zip** archive (`.zip`, `application/zip`); entries are
  stored with DEFLATE. Chosen over `.tar.gz` for first-class support in
  the toolchain languages (Zig `std.zip` / a vendored MIT `miniz` for the
  `qube` CLI; `fflate` on the Workers registry) and native double-click /
  drag-and-drop extraction on Windows. DEFLATE and the zip format are
  unencumbered (RFC 1951; no patents), like gzip.
- Layout: a single root directory whose name is `<qube-name>-<version>`,
  with any `/` in a scoped `org/qube` name replaced by `-` — e.g.
  `q64/webmcp-client` at `0.1.0` packs under `q64-webmcp-client-0.1.0/`.
  The directory holds `qube.json5` at its root plus the file set described
  below. The directory name is presentational only: a qube's canonical
  identity is its manifest `name` / `version` plus the archive's SHA-256
  (below), so the dash-flattening need not be reversible.
- Default file set (when `include` is **absent** in the manifest):
  `qube.json5`, every file under `src/`, every file under `tests/`,
  every file under `examples/` (and a top-level `example/`), the README
  (whatever path `readme` names, or `README.md` if unset), and every
  `LICENSE-*` file at the project root. Examples ship by default so an
  installed qube carries runnable usage guidance for humans and coding
  agents; a qube with heavy example assets trims them with `exclude`.
- When `include` is **present**, the file set is exactly the union
  of the default set above and the `include` globs. `include` adds
  to the default; it never replaces it. (Manifests that need to
  *remove* a default-included file use `exclude`.)
- `exclude` is applied last and may drop any file the previous
  steps would have included, default or not.
- Maximum unpacked size: TBD (likely 50 MB for v0; raise via owner
  request).
- SHA-256 of the archive is the canonical identifier; the registry
  computes it at publish time (per "Write — publish" step 3) and
  `qube.lock` records it.

## Notes on hosting

The reference deployment runs on Cloudflare Workers (handlers), R2
(archive storage), D1 (metadata, ownership), and KV (hot
indexes/search caches). The HTTP API surface above is the contract;
the storage layout is implementation-defined. Re-implementations can
ship on any stack as long as they honor this spec and the
[`qube.json5.schema.json`](./qube.json5.schema.json) it links to.
