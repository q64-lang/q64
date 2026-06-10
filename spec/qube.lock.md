# qube.lock — Lockfile reference

The machine-written file that pins a qube's resolved dependency graph.
The manifest ([`qube.json5.md`](./qube.json5.md)) declares *ranges*;
`qube.lock` records the exact versions and content digests a
resolution produced, so every later build — on any machine — resolves
to byte-identical inputs.

> **Status: draft (v0).** The file shape and lifecycle below are the
> contract; the v0 resolver floor (single-level resolution, no
> pubgrub) is called out where it shows.

## Format

**Strict JSON** — not JSON5. The lockfile is written by `qube` and
read by `qube`; it is never hand-edited, so it takes no comments and
no dialect. The filename is always literally `qube.lock`.

The serialization is **deterministic**: entries sorted by `name`
(bytewise), two-space indent, a fixed field order (the table below),
and a trailing newline. Re-locking an unchanged graph produces a
byte-identical file, so lockfile diffs are exactly dependency diffs.

```json
{
  "version": 1,
  "qubes": [
    {
      "name": "dev.q64.audio",
      "version": "0.3.2",
      "source": "registry+https://qubes.q64.dev",
      "sha256": "abcdef0123…",
      "effects": ["@audio", "@io"]
    },
    {
      "name": "dev.example.local_dep",
      "version": "0.1.0",
      "source": "path+../local-dep"
    }
  ]
}
```

## Top level

| Field     | Type   | Meaning                                                          |
|-----------|--------|-------------------------------------------------------------------|
| `version` | int    | Lockfile format version. This document describes `1`.            |
| `qubes`   | array  | One entry per resolved qube, sorted by `name`.                   |

A reader that encounters a `version` it does not understand fails
with `PKG013` rather than guessing.

## Entry fields

| Field          | Type     | Present              | Meaning                                                                  |
|----------------|----------|----------------------|---------------------------------------------------------------------------|
| `name`         | string   | always               | Full qube name (= module path), e.g. `dev.q64.audio`.                    |
| `version`      | string   | always               | The exact resolved semver.                                               |
| `source`       | string   | always               | Where the qube came from: `registry+<url>` or `path+<relative-path>`.    |
| `sha256`       | string   | registry sources     | The archive's canonical SHA-256, as computed and returned by the registry (per [`continuum-api.md`](./continuum-api.md) §"Write — publish"). The cache key. |
| `effects`      | [string] | registry sources, when the registry supplied it | The version's *detected* effect set from the registry's effect index — lets `qube audit` work offline. |
| `dependencies` | [string] | when non-empty       | Names of this entry's own dependencies; their versions are pinned by their own entries. |

**Path sources carry no digest.** A `path+` dependency's content is
whatever is on disk; the lockfile records its identity (name, the
version its manifest declared at lock time, and the path as written
in the manifest) but cannot content-address it. Reproducibility for
path deps is the repository's job, not the lockfile's.

## Location

Next to the `qube.json5` it locks. In a workspace, there is **one**
lockfile, at the workspace root (per
[`qube-cli.md`](./qube-cli.md) §"Manifest discovery" — the workspace
sets the lockfile location); members do not carry their own.

**Commit it.** Applications and libraries both: a committed lockfile
is what makes CI, a collaborator's first clone, and a six-months-later
rebuild resolve identically. (`target/` stays ignored; `qube.lock`
does not.)

## Lifecycle

**Written by:**

- `qube add <dep>[@version]` — resolves the new dependency, then
  upserts its entry (and, once transitive resolution lands, the
  entries it pulls in).
- `qube lock` — regenerates the whole file from the manifest:
  re-resolves every range, reusing locked versions that still satisfy
  their range rather than bumping them.
- `qube install` — writes the file if it is missing or stale (per
  [`continuum-api.md`](./continuum-api.md) §"Resolver protocol").

**Read by:**

- `qube build` / `qube run` / `qube web` — a registry dependency is
  resolved **only** through the lockfile: entry → `sha256` →
  `~/.qube/cache/sha256/<ab>/<cd>/<digest>/src` → `--module` flag.
  The build path never touches the network.
- `qube install` — fetches whatever locked entries the cache is
  missing; with `--offline`, a cache miss is an error instead.
- `qube audit` — reads locked `effects` when offline.

## Staleness

The lockfile **satisfies** the manifest when every dependency in the
manifest has an entry whose `source` kind matches and whose `version`
satisfies the declared range. When it does not (a range was edited, a
dep added by hand, a path dep re-pointed):

- `qube build` / `run` / `web` report which name is unlocked
  (`PKG010`) or out of range (`PKG011`) and how to fix it
  (`qube lock`). v0 does **not** silently re-resolve during a build.
- `qube lock` repairs it.
- `--frozen` makes any would-be lockfile write an error;
  `--locked` additionally permits network fetches that agree with the
  lockfile (per [`qube-cli.md`](./qube-cli.md) §"Global options").

A locked version that has since been **yanked** still resolves: the
registry keeps yanked archives downloadable for existing lockfiles
and only hides them from new resolution (per
[`continuum-api.md`](./continuum-api.md) §"Write — yank / unyank").

## v0 resolver floor

What the contract above promises but the v0 implementation narrows:

- **Single-level resolution.** Direct dependencies only; a registry
  dep's own registry deps are not yet walked (the test corpus has
  none). Pubgrub-style full resolution per
  [`continuum-api.md`](./continuum-api.md) §"Resolver protocol" is
  the v1 item, and `dependencies` entries exist in the format so it
  lands without a format bump.
- **Range forms.** Exact (`0.3.2`) and caret (`^0.3`, `^0.3.2`)
  ranges — the forms `qube add` writes. Comparison ignores
  prerelease tags.
- **`effects` is best-effort.** Recorded when the registry metadata
  carries the index; absent otherwise.

## Diagnostic codes

Lockfile diagnostics use the `PKG` band (per
[`diagnostics.md`](./diagnostics.md) §"Code conventions"),
`PKG010`–`PKG019`. Numbers are stable, never reused.

| Code     | Short message                              | When                                                                       |
|----------|--------------------------------------------|------------------------------------------------------------------------------|
| `PKG010` | dependency is not locked                   | A manifest registry dep has no `qube.lock` entry; run `qube lock` or `qube add`. |
| `PKG011` | locked version does not satisfy manifest   | The entry's `version` is outside the manifest's declared range.             |
| `PKG012` | locked archive missing from cache          | The entry's `sha256` has no extracted cache directory; run `qube install` (or drop `--offline`). |
| `PKG013` | malformed or unsupported lockfile          | `qube.lock` is not valid JSON, or its `version` is unknown.                 |

## Related specs

- [`qube.json5.md`](./qube.json5.md) — the manifest whose ranges this
  file pins.
- [`qube-cli.md`](./qube-cli.md) — `add` / `lock` / `install`, the
  `--offline` / `--frozen` / `--locked` flags, cache layout.
- [`continuum-api.md`](./continuum-api.md) — resolver protocol,
  archive content-addressing, yank semantics.
