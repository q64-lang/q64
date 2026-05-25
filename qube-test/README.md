# qube-test

Black-box CLI conformance suite for the `qube` binary. Each test spawns the
built binary and asserts on **exit code**, **stdout**, and the **stderr
diagnostic envelope** (PKG / REG2 prefixes for qube's own diagnostics, plus
q64's envelopes forwarded verbatim — `spec/qube-cli.md`, `spec/diagnostics.md`).

Coverage is scoped to the **spec** (`spec/qube-cli.md`, `spec/qube.json5.md`),
not the current implementation: per `CLAUDE.md`, "when the spec and the code
disagree, the spec is right." Subcommands the binary does not implement yet are
encoded as `.todo`. Where the binary ships an explicit "not implemented yet"
stub today, the suite pins that stub's exit code as a real test so the
transition to a real implementation is visible.

## Running

```sh
# Build the binary first (from the repo root):
. ./vendor/zig/activate && (cd qube && zig build)

# Then run the suite:
cd qube-test
bun test
```

The binary is located via `$QUBE_BIN`, defaulting to `../qube/zig-out/bin/qube`.
When the binary is absent, spawn-based suites **skip** rather than fail, so
`bun test` stays green before the toolchain is built. Note that `qube run` and
`qube web` shell out to `q64` and a runtime host, so those paths need the full
toolchain built; the failure paths that don't (manifest discovery, usage) run
on the `qube` binary alone.

```sh
QUBE_BIN=/path/to/qube bun test
bun test tests/usage.test.ts
```

## Layout

Mirrors `q64-test`: the primary axis is the CLI command tree (one file per
subcommand, matching the §Subcommands table of `spec/qube-cli.md`); the
secondary axis, `tests/contract/`, covers cross-cutting guarantees — the
exit-code table, envelope framing, the q64-subprocess invocation contract, and
global flags.

```
tests/
  run.test.ts          # `qube run`: manifest discovery, entry resolution
  web.test.ts          # `qube web`: target/web layout, port selection
  add.test.ts          # `qube add <dep>`: resolve, download, edit manifest
  publish.test.ts      # `qube publish`: pack + upload flow
  login.test.ts        # `qube login`
  new-init.test.ts     # `qube new` / `qube init` scaffolding
  build.test.ts        # `qube build`: orchestration, target/ layout, exit codes
  manifest.test.ts     # qube.json5 parsing / validation / discovery
  workspace.test.ts    # `qube workspace`: member discovery / filtering
  add-remove.test.ts   # manifest + lockfile mutations
  usage.test.ts        # unknown subcommands + not-yet-implemented stubs
  contract/            # exit codes, diagnostics framing, subprocess contract, flags
```
