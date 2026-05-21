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
| `qube add <dep> [@version]`      | Add a dependency to the manifest, resolve it, update the lockfile  |
| `qube remove <dep>`              | Remove a dependency                                                |
| `qube build [--target <name>]`   | Compile this qube to wasm                                          |
| `qube run [--target <name>]`     | Build and run                                                      |
| `qube test`                      | Run the qube's tests                                               |
| `qube install`                   | Fetch all dependencies into the local cache                        |
| `qube lock`                      | Regenerate `qube.lock` from the manifest                           |
| `qube publish`                   | Publish this qube to the registry                                  |
| `qube outdated`                  | List dependencies with newer compatible versions                   |
| `qube audit`                     | Show effects and capabilities each dependency declares             |
| `qube clean`                     | Remove build outputs (`target/`)                                   |
| `qube fmt`                       | Format every `.q` source in this qube (delegates to `q64 fmt`)     |
| `qube workspace <subcommand>`    | Workspace operations (`members`, `each`, …)                        |

## Global options

| Flag                              | Meaning                                                                   |
|-----------------------------------|---------------------------------------------------------------------------|
| `--manifest <path>`               | Path to a specific `qube.json5` (default: nearest ancestor)               |
| `--target <name>`                 | Target name from the manifest's `targets` map                             |
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
    <qube-name>.runtime.{js,zig}      # runtime adapter for the chosen target host
    <qube-name>.effects.json          # effect index emitted by q64
    <qube-name>.graph.json            # stream-graph topology (if any stages)
  release/                     # `--release`
  test/                        # test executables
  <target-name>/               # named targets from qube.json5
```

`target/` is `.gitignore`-default, like Cargo's.

## Dependency cache layout

Resolved dependencies are extracted to a user-global cache:

```
~/.qube/
  cache/                       # extracted tarballs, content-addressed
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
then for each `.q` source file invokes:

```
q64 build <file.q>
  --diagnostics json
  --target <triple-or-name>
  --module q64.math=<cache>/q64-math-0.3.1/src
  --module q64.audio=<cache>/q64-audio-0.3.0/src
  ...
  --out target/<host>/<obj>.wasm
```

`qube` parses the newline-delimited diagnostic envelopes on stderr,
renders them in the user's chosen format, and aggregates exit codes.
The subprocess contract is documented in [`q64-cli.md`](./q64-cli.md)
under "Subprocess invocation contract".

Why a subprocess: clean version boundary, easy mocking in tests,
independent crash recovery. A later flag (`qube build --in-process`)
may link the compiler library directly for incremental scenarios where
subprocess overhead matters.

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
3. Build the include/exclude file list; pack to `.tar.gz`.
4. Run a clean build against the **release** profile to confirm it
   compiles (errors abort publish).
5. Authenticate against the registry using `~/.qube/credentials.toml`.
6. Upload tarball; the registry validates schema, checks ownership,
   indexes effects.
7. Cache the published version locally.

On failure, `qube` emits a diagnostic-envelope error with `severity:
"error"` and exits with code `67`.
