# q64-test

Black-box CLI conformance suite for the `q64` binary. Each test spawns the
built binary, feeds optional stdin, and asserts on **exit code**, **stdout**,
and the **stderr diagnostic envelope** — the part of the CLI contract the
source-level conformance corpus (`spec/tests/`) deliberately does not exercise.

Coverage is scoped to the **spec** (`spec/q64-cli.md`), not the current
implementation: per `CLAUDE.md`, "when the spec and the code disagree, the spec
is right." Commands the binary does not implement yet are encoded as `.todo`
cases that flip green as the CLI catches up to the spec.

## Running

```sh
# Build the binary first (from the repo root):
. ./vendor/zig/activate && (cd q64 && zig build)

# Then run the suite:
cd q64-test
bun test
```

The binary is located via `$Q64_BIN`, defaulting to `../q64/zig-out/bin/q64`
(the same default as `q64/scripts/run-conformance.sh`). When the binary is
absent, spawn-based suites **skip** rather than fail, so `bun test` stays green
in environments where the toolchain hasn't been built.

```sh
Q64_BIN=/path/to/q64 bun test        # test a specific binary
bun test tests/check.test.ts         # run one file
```

## Layout

The primary axis mirrors the CLI command tree (one file/folder per subcommand,
matching the §Subcommands and §`show` tables of `spec/q64-cli.md`). The
secondary axis, `tests/contract/`, covers the spec's cross-cutting sections —
exit codes, stdin/stdout/stderr routing, envelope framing, and global flags —
that apply across every command.

```
tests/
  check.test.ts        # `q64 check` — the implemented diagnostic command
  run.test.ts          # `q64 run` + implicit run
  build.test.ts        # `q64 build` / `q64 emit`, --out, --component
  fmt.test.ts          # `q64 fmt` --stdout / --check / --lint
  explain.test.ts      # `q64 explain <code>`
  lsp.test.ts          # `q64 lsp`
  show/                # `q64 show <kind>` — one file per kind group
  contract/            # exit codes, diagnostics framing, IO routing, global flags
```
