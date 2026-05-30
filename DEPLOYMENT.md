# Deployment

How the q64 web properties and the q64 / qube binary releases ship, and what
each one needs to be **enabled**. Three Cloudflare Workers + one GitHub release,
plus a sibling concern in the qubepods repo.

| Target | Worker / artifact | Where | How |
|---|---|---|---|
| **q64.dev** | `q64-web` | `web/` | `pnpm run deploy` |
| **docs.q64.dev** | `q64-docs` | `q64-docs/` | `pnpm run deploy` |
| **q64 + qube binaries** | GitHub Release `nightly` | `.github/workflows/release.yml` | manual (`workflow_dispatch`) |
| **macOS binaries** | release assets | `scripts/release-mac.sh` | run on a Mac |
| **qubepods.com `.well-known`** | `qubepods-web` | *qubepods repo* `apps/web/` | `pnpm -C apps/web deploy` |

## Prerequisites

### Cloudflare (the three Workers)
- Account: **Cf@etiamo.com**, id `ff91a5b2b5023767bac4e8536ba981a9` (hosts the
  `q64.dev` zone and all `q64-*` Workers).
- `wrangler` must be authenticated (`wrangler whoami`). Two accounts are visible
  on this machine, so **every** deploy must pin the account:

  ```sh
  export CLOUDFLARE_ACCOUNT_ID=ff91a5b2b5023767bac4e8536ba981a9
  ```

  Without it wrangler errors with "More than one account available". Use
  `pnpm run deploy` (not `pnpm deploy` — that collides with pnpm's own
  subcommand).

### GitHub (the release)
- `gh` authenticated for `q64-lang/q64` (used by `scripts/release-mac.sh`).
- The toolchain vendored locally: `WASMTIME_SHA256=skip ./init.sh`, then
  `export PATH="$PWD/vendor/zig:$PATH"` (plain `./init.sh` aborts on the
  unpinned wasmtime sha; `q64`/`qube` only need Zig + Binaryen).

## q64.dev — the landing site (`q64-web`)

```sh
cd web
CLOUDFLARE_ACCOUNT_ID=ff91a5b2b5023767bac4e8536ba981a9 pnpm run deploy
```

Astro + Starlight static build served by the Worker. The `q64.dev` custom
domain is already attached (Cloudflare dashboard), so deploys are content-only.
Search is disabled here (`pagefind: false` in `web/astro.config.mjs`) — there
is no real content to index; full search lives on docs.q64.dev.

## docs.q64.dev — the language docs (`q64-docs`)

```sh
cd q64-docs
CLOUDFLARE_ACCOUNT_ID=ff91a5b2b5023767bac4e8536ba981a9 pnpm run deploy
```

`pnpm run deploy` runs the `prebuild` generator (`scripts/gen-docs.mjs`) then
`astro build && wrangler deploy`. The generator renders the **reference** pages
(keywords, builtin types, diagnostics) from `doc.json`, mirrors `spec/*.md`,
emits `/llms.txt` + `/llms-full.txt`, and copies the brand/theme from `web/`.

`doc.json` is resolved in order: `$DOC_JSON` → `$Q64_BIN doc --json` →
`q64/zig-out/bin/q64 doc --json` → the committed `q64-docs/fixtures/doc.json`
(so it works offline / without a build). To render against the latest compiler:

```sh
( cd q64 && zig build )   # produces q64/zig-out/bin/q64
```

The `docs.q64.dev` custom domain is in `q64-docs/wrangler.jsonc` (`routes`), so
the first `wrangler deploy` provisions it automatically. Generated output
(`reference/`, `spec/`, `llms*.txt`, copied brand/theme) is gitignored.

### Auto-deploy (optional)

`.github/workflows/docs.yml` deploys docs.q64.dev on push to `main` (paths
`q64-docs/**`, `spec/**`) **and** when a release publishes a fresh `doc.json` —
**without** building Zig (it downloads the `doc.json` release asset). To enable
it, add two **repo secrets**:

- `CLOUDFLARE_API_TOKEN` — a token with Workers Scripts + Workers Routes edit on
  the etiamo account.
- `CLOUDFLARE_ACCOUNT_ID` — `ff91a5b2b5023767bac4e8536ba981a9`.

Until they exist the workflow **skips the deploy and stays green** (it does not
fail); deploy manually with the command above.

## Binary release — q64 + qube (+ doc.json)

The release is a **manual** action — it does **not** run on routine pushes to
main (we push far more often than we release). Refresh the rolling `nightly`:

```sh
gh workflow run release.yml --ref main      # or Actions → release → Run workflow
```

Push a `vX.Y.Z` tag for an immutable stable release instead. Either way it builds
**linux-amd64** `q64` + `qube` (ReleaseFast) and updates the `nightly` release:

```
q64-linux-amd64  qube-linux-amd64  SHA256SUMS  manifest.json  doc.json
```

`manifest.json` is the contract the **qubepods builder container** reads to
fetch (and sha-verify) the binaries. The action **updates** `nightly` in place
(it no longer deletes/recreates it) and only clobbers the files it builds, so
**out-of-band assets like the macOS binaries survive** across releases.

> After a release that changes the compiler, **rebuild / repin the qubepods
> builder container** so it picks up the new `q64`/`qube` (e.g. to use
> `q64 doc` / `q64 explain`).

### macOS binaries

CI has **no hosted macOS or arm runners**, and `q64` links a host-built Binaryen
static lib (so it can't be cross-compiled from linux). Build them on a Mac and
attach them to the release:

```sh
# after the nightly release exists (you've run the release action)
scripts/release-mac.sh           # TAG defaults to "nightly"
```

Because the release action updates `nightly` in place (never deletes it), these
mac binaries persist across subsequent releases — re-run this only when you want
to refresh them for a new compiler build.

It builds the host arch (arm64 on Apple Silicon, amd64 on Intel) and
`gh release upload`s `q64-darwin-<arch>` + `qube-darwin-<arch>`. Run it once on
each Mac arch you want to publish.

#### Gatekeeper

The mac binaries are **ad-hoc signed, not notarized**. A copy downloaded from
the release page carries `com.apple.quarantine`, so macOS blocks it with
*"Apple could not verify …"*. Clear it per file:

```sh
xattr -d com.apple.quarantine ./qube ./q64    # or: xattr -dr … <dir>
chmod +x ./qube ./q64
```

(Locally **built** binaries have no quarantine and run as-is.) To remove the
warning for everyone, sign with an Apple Developer ID + notarize
(`codesign --options runtime` → `xcrun notarytool submit --staple`) — needs a
paid Apple Developer account; not wired up yet.

## qubepods.com `.well-known` (sibling repo)

The AI-agent discovery files (`/.well-known/qubepods.json`, `/llms.txt`) live in
the **qubepods** repo, not here. Deploy from there:

```sh
cd <qubepods-repo>/apps/web
pnpm run deploy        # prebuild regenerates the files from scripts/gen-well-known.mjs
```

It advertises docs.q64.dev, the deploy API, the hosted MCP, and the manifest
schema. The schema host (`schemas.qubepods.com`) is still pending; the manifest
flags service status accordingly.
