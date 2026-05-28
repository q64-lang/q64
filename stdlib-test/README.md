# stdlib-test

Build/test conformance suite for the q64 **standard library** (`../stdlib`).

`stdlib/` is a qube workspace — one qube per namespace (`q64.math`, `q64.net`,
`q64.fs`, …). This suite drives the real stdlib qubes through the toolchain and
asserts exit codes:

- **builds** — `qube build` in each `stdlib/<ns>` and from the workspace root.
- **tests** — `qube test` in each `stdlib/<ns>` and from the workspace root
  (runs the namespace's in-language `@test` functions).
- **consumers** — a minimal program importing `q64.<ns>` compiles via `q64 emit`
  (coarse "the namespace resolves and its named surface exists" smoke).

## Test-first

The stdlib is **not implemented yet** — each `stdlib/<ns>` holds only a README,
there is no `.q` source, and there is no detailed per-namespace API spec (only
the one-line surface summaries in `stdlib/README.md`). So:

- Every case is `test.failing`: a real assertion that is red today and flips the
  suite red the moment a namespace starts building/testing/compiling — the
  signal to drop `.failing`.
- Assertions are deliberately coarse (exit-code level). They do **not** assume
  method signatures; consumer fixtures use only the type names listed in each
  namespace's README. Deeper, per-namespace surface tests should be added as
  each namespace gets real source and an API spec.

## Running

```sh
# Build the toolchain first (from the repo root):
. ./vendor/zig/activate && (cd q64 && zig build) && (cd qube && zig build)

cd stdlib-test
bun test
```

Binaries are located via `$QUBE_BIN` / `$Q64_BIN`, defaulting to their
`zig-out` builds. When a binary is absent, spawn suites skip rather than fail.
