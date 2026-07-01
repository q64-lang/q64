# Deploying a Qube

How to ship a q64 application. Two verbs, two destinations — don't mix
them up:

| You have | Verb | Destination |
|---|---|---|
| An application (a **Qube** — `type: "application"`, has `main`) | `qube deploy` | [qubepods](https://qubepods.com) — the hosting runtime |
| A library (a **qube** — `type: "library"`, exports a surface) | `qube publish` | the Continuum — browse at [continuum.q64.dev](https://continuum.q64.dev) |

This page covers the first. For publishing libraries, see
[`spec/qube-cli.md` §"qube publish"](./spec/qube-cli.md).

> **qubepods is currently in private preview.** The build/manifest
> steps below work for everyone; the deploy itself (step 3's
> console-minted token onward) requires an invited account.

## TL;DR

```sh
qube build --component --addr wasm32        # 1. build the component
qube pod login                              # 2. paste a token from the qubepods console
qube deploy                                 # 3. pack + upload the bundle
```

`qube deploy` reads the qube's own `qube.json5` — there is **no** separate
deploy manifest to scaffold, and it is the **same command** in the qubepods web
shell and a terminal. Each step in detail below; the full flag reference is
[`spec/qube-cli.md`](./spec/qube-cli.md) §"`qube deploy`".

## 0. Get the toolchain

Either download `q64` + `qube` from the
[nightly release](https://github.com/q64-lang/q64/releases/tag/nightly)
(linux-amd64 + macOS), or build from source:

```sh
./init.sh                          # vendors zig, Binaryen, wasmtime
( cd q64 && ../vendor/zig/zig build )
( cd qube && ../vendor/zig/zig build )
```

**macOS note:** the downloaded mac binaries are ad-hoc signed, not
notarized, so Gatekeeper blocks them with *"Apple could not verify …"*.
Clear the quarantine bit per file:

```sh
xattr -d com.apple.quarantine ./qube ./q64
chmod +x ./qube ./q64
```

(Locally built binaries have no quarantine and run as-is.)

## 1. Build

```sh
qube build --component --addr wasm32
```

- `--component` emits the WebAssembly **component**
  (`<name>.component.wasm`) the QubePod manifest points at.
- `--addr` picks the address space (per
  [`spec/memory.md` §"The platform"](./spec/memory.md)): **`wasm32` is
  the universal baseline** — it is the only one that runs on
  WebKit/Safari/iPad. `wasm64` adds Memory64 for capable hosts. To ship
  both, build both and declare them as variants in step 2.

Output lands under `target/<profile>/<addr>/`.

## 2. Declare the deploy target in `qube.json5`

There is **no separate deploy manifest** — `qube deploy` reads the qube's own
`qube.json5`. Point `component` at the artifact to ship:

- `component.module` — a classic JS worker entry (no wasm on the server).
- `component.wasm` — a single wasm component / core module.
- `component.variants.{wasm32,wasm64}.wasm` — one build per address space, the
  recommended shape for a Qube that must reach WebKit *and* wants 64-bit
  elsewhere.

Optional `assets.directory` ships a static asset tree alongside the artifact,
and an `exports.http` route exposes an HTTP handler. See
[`spec/qube.json5.md`](./spec/qube.json5.md).

## 3. Authenticate

Mint a token in the qubepods console (**private preview** — invited
accounts only for now), then:

```sh
qube pod login        # reads the token from stdin (or --token <t>)
```

Tokens are stored in `~/.qube/pods.toml`, separate from your Continuum
registry credentials (`~/.qube/credentials.toml`) — the two never
clobber each other. `qube deploy` resolves its token in order:
`--token` → `$QUBEPODS_TOKEN` → the saved login. `qube pod info` shows
the provider and auth status; `qube pod logout` forgets the token.

## 4. Deploy

```sh
qube deploy
```

Packs a bundle zip (`target/deploy/<name>.zip`) from the `qube.json5` in the
current directory — manifest, the component artifact (JS module, single wasm,
or per-variant), and the asset tree — and uploads it. The server
content-addresses the artifact and assets into your tenant store and
materializes the deployment. The **same command** runs in the qubepods web
shell.

## Test locally first

You don't need a deploy to iterate:

```sh
qube run        # build + run under the local wasmtime host
qube web        # serve the browser build locally
```

---

*How the q64 project's own web properties (q64.dev, docs.q64.dev) ship
is a maintainer concern and intentionally not documented here —
contributors change them by PR, like everything else.*
