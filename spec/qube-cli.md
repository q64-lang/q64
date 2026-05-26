# `qube` CLI — package and build tool reference

The CLI surface of the `qube` binary. `qube` operates on qube *projects*
(directories containing a [`qube.json5`](./qube.json5.md) manifest).
Source-level operations live in [`q64`](./q64-cli.md); `qube` invokes
`q64` internally per source file, the same way `cargo` invokes `rustc`.

> **Status: draft (v0).**

## Synopsis

```
qube <subcommand> [options] [args...]
qube --version | -v
qube --help    | -h
```

## Subcommands

| Subcommand                       | Purpose                                                            |
|----------------------------------|--------------------------------------------------------------------|
| `qube new <name>`                | Create a new qube directory with a starter manifest and `src/`     |
| `qube init`                      | Initialize a qube in the current directory                         |
| `qube pod <new\|init>`           | Scaffold a QubePod deploy manifest (`qubepod.jsonc`)               |
| `qube add <dep> [@version]`      | Add a dependency to the manifest, resolve it, update the lockfile  |
| `qube remove <dep>`              | Remove a dependency                                                |
| `qube build [--target <name>]`   | Compile this qube to wasm                                          |
| `qube run [--target <name>]`     | Build and run                                                      |
| `qube web`                       | Build to wasm and serve in a browser via the browser adapter       |
| `qube test`                      | Run the qube's tests                                               |
| `qube install`                   | Fetch all dependencies into the local cache                        |
| `qube lock`                      | Regenerate `qube.lock` from the manifest                           |
| `qube publish`                   | Publish this qube to the registry                                  |
| `qube outdated`                  | List dependencies with newer compatible versions                   |
| `qube audit`                     | Show effects and capabilities each dependency declares             |
| `qube clean`                     | Remove build outputs (`target/`)                                   |
| `qube explain <code>`            | Print structured documentation for a diagnostic code               |
| `qube fix`                       | Apply or plan automated repairs from diagnostic `repair` fields    |
| `qube fmt`                       | Format every `.q` source in this qube (delegates to `q64 fmt`)     |
| `qube workspace <subcommand>`    | Workspace operations (`members`, `each`, …)                        |

## Global options

| Flag                              | Meaning                                                                   |
|-----------------------------------|---------------------------------------------------------------------------|
| `--manifest <path>`               | Path to a specific `qube.json5` (default: nearest ancestor)               |
| `--target <name>`                 | Target name from the manifest's `targets` map                             |
| `--component`                     | On `build` / `run`: also emit a component wrapping the core module (overrides `component.emit`). Delegates to `q64 build --component`; writes `target/<host>/<name>.component.wasm` alongside the core module. See [`qube.json5.md` §Component](./qube.json5.md). |
| `--release` / `--debug`           | Shortcuts for `optimize: speed` / `optimize: debug`                       |
| `--offline`                       | Refuse network access; fail if cache misses                               |
| `--frozen`                        | Refuse to update the lockfile; fail if it would change                    |
| `--locked`                        | Like `--frozen` but allow lockfile-consistent network fetches             |
| `--diagnostics <text\|json>`      | Pass through to `q64`; affects `qube`'s own diagnostics too               |
| `--no-color`                      | Disable ANSI color                                                        |
| `--quiet` / `-q`                  | Suppress non-error output                                                 |
| `--verbose` / `-v`                | Verbose logging to stderr                                                 |
| `--registry <url>`                | Override the default registry                                             |
| `-jN`                             | Parallelism for builds (default: number of CPUs)                          |

## Manifest discovery

`qube` walks upward from `cwd` until it finds a `qube.json5`, then
upward further until it finds one with `type: "workspace"`. The closest
non-workspace manifest is the *current qube*; the workspace (if any)
sets shared dependency versions and lockfile location.

Override: `--manifest <path>` skips discovery.

## `target/` layout

Build outputs land under `target/` next to `qube.json5`:

```
target/
  debug/                       # default for `qube build`
    <qube-name>.wasm
    <qube-name>.component.wasm        # only with --component / component.emit; wraps the core module
    <qube-name>.runtime.{js,zig}      # runtime adapter for the chosen target host
    <qube-name>.effects.json          # effect index emitted by q64
    <qube-name>.graph.json            # stream-graph topology (if any stages)
  release/                     # `--release`
  test/                        # test executables
  web/                         # `qube web`: wasm + browser adapter shell
    <qube-name>.wasm
    host.js
    index.html
  <target-name>/               # named targets from qube.json5
```

## `qube new`, `qube init`, and `qube pod` (v0)

These scaffold new manifests. Every scaffolder supports two modes:

- **Flag-driven** — when *any* flag is passed, the command runs
  non-interactively and takes all values from flags (and defaults).
- **Wizard** — when *no* flags are passed, the command prompts for each
  field on stdin; an empty answer accepts the shown `[default]`.

Generated files are never overwritten: an existing target manifest aborts
with exit `65` (input).

### `qube new` / `qube init`

`qube new <name>` creates a directory named after the qube (override with
`--dir`); `qube init` writes into the current directory (defaulting the name
to the directory's basename). Both emit a `qube.json5`, a starter entry
(`src/lib.q` for libraries, `src/main.q` for applications; none for a
workspace), and a `README.md`.

| Flag            | Default              | Meaning                                          |
|-----------------|----------------------|--------------------------------------------------|
| `--lib`         | (the default kind)   | Library qube (`type: "library"`).                |
| `--app`         |                      | Application Qube (`type: "application"`).         |
| `--workspace`   |                      | Workspace root (`type: "workspace"`).             |
| `--name <name>` | positional / cwd base| Qube name.                                       |
| `--version <v>` | `0.1.0`              | Semver.                                          |
| `--license <s>` | `MIT OR Apache-2.0`  | SPDX expression.                                 |
| `--description` | —                    | One-line description.                            |
| `--dir <path>`  | the name (`new` only)| Target directory.                                |

The starter manifest always sets the three required fields (`name`,
`version`, `license`; see [`qube.json5.md`](./qube.json5.md)) plus `type` and
`entry`. Names should be reverse-DNS (`dev.q64.audio`); a name that is not
publishable (fewer than two dotted lowercase segments) still scaffolds but
prints a note, since publishability is only enforced at `qube publish`.

### `qube pod`

`qube pod new <name>` / `qube pod init` scaffold a QubePod deploy manifest
(`qubepod.jsonc`) for [qubepods](https://qubepods.com). The mandatory fields
mirror the QubePod schema: `apiVersion`, `kind` (`"QubePod"`), `project` (a
`[a-z0-9][a-z0-9-]*` slug), `name`, and a `component` with `wasm` and
`wit.{package,world}`.

| Flag                  | Default                    | Meaning                              |
|-----------------------|----------------------------|--------------------------------------|
| `--project <slug>`    | — (required)               | Project slug, e.g. `image-tools`.    |
| `--name <name>`       | positional / cwd base      | App/qube name.                       |
| `--wasm <path>`       | — (required)               | Path to the wasm component.          |
| `--wit-package <id>`  | — (required)               | WIT package id.                      |
| `--wit-world <world>` | — (required)               | WIT world name.                      |
| `--language <lang>`   | —                          | Source language (optional).          |
| `--version <semver>`  | —                          | Manifest version (optional).         |
| `--api-version <ver>` | `qubepods.dev/v0.1`        | `apiVersion`.                        |
| `--http-route <r>`    | —                          | Add an `exports.http` block at `r`.  |
| `--http-interface <id>`| `qubepods:http/handler`   | http export interface.               |
| `--dir <path>`        | the name (`new` only)      | Target directory.                    |

## `qube web` (v0)

`qube web` mirrors `qube run` for the browser target. It compiles the
qube's entry to `target/web/<name>.wasm` via `q64 emit`, copies the
browser adapter from `runtime/browser/` (override with the
`Q64_BROWSER_ADAPTER` env var) into the same directory — `host.js`
verbatim, `index.html` with `{{WASM}}` replaced by the artifact's
filename — picks a free port in `[4711, 4720]`, spawns
`python3 -m http.server` against `target/web/`, and opens the default
browser at `http://localhost:<port>/`. The command stays in the
foreground until the server exits (Ctrl-C). Exit codes follow the
table below.

The browser adapter implements the same `env.out :: (ptr: i32, len:
i32) -> ()` ABI as the Wasmtime host; see `runtime/browser/host.js`.
A built-in server (replacing `python3`) is deferred.


`target/` is `.gitignore`-default, like Cargo's.

## Dependency cache layout

Resolved dependencies are extracted to a user-global cache:

```
~/.qube/
  cache/                       # extracted archives, content-addressed
    sha256/ab/cd/abcdef…/
      qube.json5
      src/...
  registry/                    # registry-specific metadata
    qubes.q64.dev/
      index/                   # sparse index (Cargo-style)
      qubes/<name>/<version>.json
  credentials.toml             # auth tokens per registry
```

`QUBE_HOME` overrides `~/.qube`. CI systems pin caches via this variable.

## How `qube` invokes `q64`

`qube build` walks the dependency graph (workspace + transitive deps),
then for each qube's top-level entry file (per its manifest's
`entry`) invokes:

```
q64 build <entry.q>
  --diagnostics json
  --target <triple-or-name>
  --module dev.q64.audio=<absolute-path>/dev.q64.audio-0.3.0/src
  --module com.openai.whisper=<absolute-path>/com.openai.whisper-1.0.2/src
  --module dev.example.local_dep=/abs/path/to/local-dep/src   # path: deps look identical
  --features fft,mp3                                    # union of activated features
  ...
  --out target/<host>/<qube-name>.wasm
```

One invocation per qube, one `--out` per invocation. Cross-qube
imports are resolved entirely through `--module`; `q64` never
reads `qube.json5` itself. Local-path dependencies (`path: "…"`
in the manifest) are normalised to absolute filesystem paths and
passed via `--module` exactly the same way registry-resolved
dependencies are — the compiler cannot tell the two sources
apart.

`qube` parses the newline-delimited diagnostic envelopes on
`q64`'s stderr and **forwards them verbatim** (re-rendering in
text mode if the user requested `--diagnostics text`). It does
not wrap them in an outer envelope; a downstream consumer
(editor, CI) sees the same envelopes whether they were produced
by `q64` directly or relayed through `qube`. Aggregation across
multiple invocations happens at the exit-code level: the worst
exit code seen wins (`70` > `64` > `2` > `0`). The subprocess
contract is documented in [`q64-cli.md`](./q64-cli.md) under
"Subprocess invocation contract".

`qube`'s own diagnostics (manifest validation, registry errors,
dependency resolution) use the same envelope format with the
`PKG` / `REG2` prefixes (per
[`diagnostics.md`](./diagnostics.md) §"Code conventions") so the
downstream consumer parses one format end-to-end.

Why a subprocess: clean version boundary, easy mocking in tests,
independent crash recovery. A later flag (`qube build --in-process`)
may link the compiler library directly for incremental scenarios where
subprocess overhead matters.

## `qube fix` and `qube explain`

`qube fix` walks the project, runs `q64` per source file with
`--diagnostics json`, collects every diagnostic that carries a `repair`
field (per [`diagnostics.md`](./diagnostics.md)), and either prints a
machine-readable plan or applies it.

```
qube fix --plan                  # emit JSON plan; do not modify files
qube fix --apply                 # apply every `safety: "safe"` repair
qube fix --apply --code TYP041   # only repairs for the named code
qube fix --apply --unsafe        # include `safety: "unsafe"` repairs
qube fix --apply --dry-run       # show diff, don't write
```

The plan format is the union of all `repair` objects across the
project, plus a `summary` block:

```
{
  "summary": { "files": 12, "repairs_safe": 47, "repairs_unsafe": 3, "skipped": 0 },
  "repairs": [
    {
      "file": "src/audio/lowpass.q",
      "code": "TYP041",
      "repair": { "id": "wrap-cast", "safety": "safe", "edits": [ ... ] }
    },
    ...
  ]
}
```

AI agents driving `qube fix` typically run `qube fix --plan`, inspect
the result, then `qube fix --apply --code <subset>` for the repairs
they trust.

`qube explain <code>` delegates to `q64 explain <code>` and adds
qube-specific context (which dependency a fired diagnostic came from,
whether a fix is available via `qube fix`). Same JSON shape as
`q64 explain`.

## Exit codes

Mirrors `q64`'s table, plus a few `qube`-specific codes:

| Exit  | Meaning                                                          |
|-------|------------------------------------------------------------------|
| `0`   | Success                                                          |
| `1`   | Runtime failure during `qube run` / `qube test`                  |
| `2`   | Usage error                                                      |
| `64`  | Compile error from `q64` (any `error`-severity diagnostic)       |
| `65`  | Input error (manifest missing, malformed, etc.)                  |
| `66`  | Dependency error (resolution failure, cache miss with `--offline`) |
| `67`  | Registry error (network, auth, publish conflict)                 |
| `70`  | Internal error in `qube`, or ICE propagated from `q64`           |

## Manifest discovery in workspaces

Inside `stdlib/` (workspace root with `members: ["math", "anim", ...]`):

- `qube build` from `stdlib/` builds every member in dependency order.
- `qube build` from `stdlib/math/` builds only `math`.
- `qube test` honors `--members <glob>` to filter.

## Publishing flow

`qube publish` executes:

1. Validate `qube.json5` against the schema.
2. Refuse if `publish: false`, or if version already exists on the
   registry.
3. Build the include/exclude file list; pack to a `.zip` archive.
4. Run a clean build against the **release** profile to confirm it
   compiles (errors abort publish).
5. Authenticate against the registry using `~/.qube/credentials.toml`.
6. Upload the archive; the registry validates schema, checks ownership,
   indexes effects.
7. Cache the published version locally.

On failure, `qube` emits a diagnostic-envelope error with `severity:
"error"` and exits with code `67`.
