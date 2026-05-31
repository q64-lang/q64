# qube

The Zig project that produces the `qube` binary — the q64 **package and
build tool**.

> **Status: v0 (pre-alpha).** Implemented today: `new`, `init`, `pod`,
> `run`, `web`, `add`, `publish`, `login`. The remaining spec subcommands
> (`remove`, `build`, `test`, `fmt`, `workspace`, …) print
> "not implemented yet" and exit 2.

## Scope

`qube` operates on qube *projects* (folders with a `qube.json5` manifest).
Source-level operations (formatting, language server, introspection) belong
to the [`q64`](../q64) binary. `qube run` invokes `q64` per source file
internally — the same way `cargo build` invokes `rustc`.

## Setup

```sh
./init.sh                 # installs the pinned Zig toolchain into vendor/zig
. ./vendor/zig/activate    # or: export PATH="$PWD/vendor/zig:$PATH"
zig build                  # builds zig-out/bin/qube
zig build cli-tests        # runs the black-box suite in ../qube-test (needs bun)
```

## Creating projects

Two creation modes per command: pass **any flag** to run non-interactively
(flag-driven), or pass **no flags** to launch an interactive **wizard** that
prompts for each field on stdin.

### `qube new` / `qube init` — a Qube or qube

`qube new <name>` scaffolds a new directory (named after the qube; override
with `--dir`); `qube init` scaffolds into the current directory. Both write a
`qube.json5`, a starter `src/` entry, and a `README.md`.

```sh
qube new dev.acme.widget --app          # application Qube → src/main.q
qube new dev.acme.audio --lib           # library qube     → src/lib.q
qube new acme --workspace               # workspace root
qube new                                # interactive wizard
qube init --lib --name dev.acme.audio   # in the current directory
```

Flags: `--lib` (default) / `--app` / `--workspace`, `--name`, `--version`
(default `0.1.0`), `--license` (default `MIT OR Apache-2.0`), `--description`,
`--dir` (`new` only).

**Naming: use reverse-DNS.** A publishable qube's `name` is a reverse-DNS
dotted path with ≥2 lowercase snake_case segments — it *is* the module path,
so pick a namespace you control: `dev.q64.audio`, `com.acme.widget`,
`org.example.parser`. Single-segment names (`myapp`) work locally but are
rejected at `qube publish`; the `q64.*` namespace is reserved for the stdlib.

The three mandatory manifest fields are **`name`**, **`version`**, and
**`license`**; `type`/`entry` default by kind. See
[`../spec/qube.json5.md`](../spec/qube.json5.md).

### `qube pod new` / `qube pod init` — a QubePod deploy manifest

Scaffolds a `qubepod.jsonc` describing how to deploy a qube to
[qubepods](https://qubepods.com). `qube pod new <name>` writes into a new
directory; `qube pod init` writes into the current directory.

```sh
qube pod new resizer \
  --project image-tools --wasm ./dist/resizer.wasm \
  --wit-package "qubepods:resizer@0.1.0" --wit-world resizer \
  --language zig --http-route /resize
qube pod init                            # interactive wizard
```

Mandatory fields (from the qubepod schema): `apiVersion`, `kind` (`QubePod`),
`project` (a `[a-z0-9][a-z0-9-]*` slug), `name`, and a `component` with
`wasm` + `wit.{package,world}`. Optional: `version`, `language`, an `http`
export (`--http-route`), and provider blocks.

## Subcommands (per [`../spec/qube-cli.md`](../spec/qube-cli.md))

| Subcommand            | Purpose                                                          | v0 |
|-----------------------|------------------------------------------------------------------|----|
| `qube new <name>`     | Create a new qube                                                | ✅ |
| `qube init`           | Initialize a qube in the current directory                       | ✅ |
| `qube pod <new\|init>`| Scaffold a QubePod deploy manifest (`qubepod.jsonc`)             | ✅ |
| `qube run`            | Build and run                                                    | ✅ |
| `qube web`            | Build to wasm and serve in a browser                             | ✅ |
| `qube add <dep>`      | Add a dependency from the Continuum registry                     | ✅ |
| `qube publish`        | Publish this qube to the Continuum                               | ✅ |
| `qube login`          | Authenticate against the Continuum registry                      | ✅ |
| `qube remove <dep>`   | Remove a dependency                                              |    |
| `qube build`          | Compile this qube to wasm                                        |    |
| `qube test`           | Run tests                                                        |    |
| `qube install`        | Resolve and fetch dependencies into the local cache              |    |
| `qube lock`           | Regenerate `qube.lock`                                           |    |
| `qube outdated`       | Show available dependency upgrades                               |    |
| `qube audit`          | Show the effects and capabilities each dependency declares       |    |
| `qube clean`          | Remove build outputs (`target/`)                                 |    |
| `qube explain <code>` | Print structured docs for a diagnostic code                      |    |
| `qube fix`            | Apply or plan automated repairs from diagnostic `repair` fields  |    |
| `qube fmt`            | Format every `.q` source in this qube (delegates to `q64 fmt`)   |    |
| `qube workspace ...`  | Workspace operations (`members`, `each`, …)                      |    |

## Output

`zig-out/bin/qube`.
