# qube

The Zig project that produces the `qube` binary — the q64 **package and
build tool**.

> **Status: not yet implemented.** The `build.zig`, source tree, and
> manifest schema will land in a follow-up commit.

## Scope

`qube` operates on qube *projects* (folders with a `qube.json5` manifest).
Source-level operations (formatting, language server, introspection) belong
to the [`q64`](../q64) binary. `qube build` invokes `q64` per source file
internally — the same way `cargo build` invokes `rustc`.

Planned subcommands (per [`../spec/qube-cli.md`](../spec/qube-cli.md)):

| Subcommand            | Purpose                                                          |
|-----------------------|------------------------------------------------------------------|
| `qube new <name>`     | Create a new qube                                                |
| `qube init`           | Initialize a qube in the current directory                       |
| `qube add <dep>`      | Add a dependency from the continuum registry                     |
| `qube remove <dep>`   | Remove a dependency                                              |
| `qube build`          | Compile this qube to wasm                                        |
| `qube run`            | Build and run                                                    |
| `qube test`           | Run tests                                                        |
| `qube install`        | Resolve and fetch dependencies into the local cache              |
| `qube lock`           | Regenerate `qube.lock`                                           |
| `qube publish`        | Publish this qube to continuum                                   |
| `qube outdated`       | Show available dependency upgrades                               |
| `qube audit`          | Show the effects and capabilities each dependency declares       |
| `qube clean`          | Remove build outputs (`target/`)                                 |
| `qube explain <code>` | Print structured docs for a diagnostic code                      |
| `qube fix`            | Apply or plan automated repairs from diagnostic `repair` fields  |
| `qube fmt`            | Format every `.q` source in this qube (delegates to `q64 fmt`)   |
| `qube workspace ...`  | Workspace operations (`members`, `each`, …)                      |

## Planned structure

```
qube/
  build.zig
  build.zig.zon
  src/
    main.zig            # CLI entry + subcommand dispatch
    manifest/           # qube.json5 parser, JSON Schema
    resolver/           # dependency resolution (SAT-based or pubgrub)
    registry/           # continuum HTTP client
    builder/            # orchestrates q64 invocation, links wasm, runs tests
    workspace/          # multi-qube workspace handling
  vendor/
```

## Output

`zig-out/bin/qube`.
