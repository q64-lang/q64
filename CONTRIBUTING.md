# Contributing

Changes ship by PR — code, specs, docs, site, all of it. Contributors
never deploy anything and never need a Cloudflare account, a wrangler
login, or any infrastructure access; see
[`DEPLOYMENT.md`](./DEPLOYMENT.md) for what deployment means for *your
own* Qube.

## Setup

```sh
./init.sh                              # vendors zig, Binaryen, wasmtime (sha256-pinned)
( cd q64  && ../vendor/zig/zig build ) # the language CLI
( cd qube && ../vendor/zig/zig build ) # the package CLI
```

Build with the **vendored** zig (`vendor/zig/zig`), not a system zig —
the std APIs drift between releases and the repo pins one version.
The black-box CLI suites need [`bun`](https://bun.sh) on PATH; the
conformance runner needs `jq`.

## Test gates

Run the gates that cover what you touched; a PR should leave all of
them as green as it found them.

| Gate | Command | Covers |
|---|---|---|
| q64 unit tests | `cd q64 && ../vendor/zig/zig build test` | parser, IR, sema, codegen, doc |
| q64 CLI suite | `cd q64 && ../vendor/zig/zig build cli-tests` | `q64` black-box behavior (bun) |
| qube unit tests | `cd qube && ../vendor/zig/zig build test` | manifest, lockfile, semver, JSON5 |
| qube CLI suite | `cd qube && ../vendor/zig/zig build cli-tests` | `qube` black-box behavior (bun) |
| Conformance | `bash q64/scripts/run-conformance.sh` | `spec/tests/` fixtures vs emitted diagnostics |
| End-to-end | `./scripts/link-roundtrip.sh` | emit + link + run on wasm32 **and** wasm64 |

Some conformance fixtures intentionally fail (they pin diagnostics the
compiler doesn't emit yet — test-first); the bar is **no regressions**
in the passed count.

## Conventions

- **The spec is the answer key.** When `spec/*.md` and the code
  disagree, the spec is right and the code is a bug. Behavior changes
  land together with their spec edit.
- **Honest diagnostics.** A construct the compiler can't handle yet is
  a clean `UnsupportedExpression`-class error — never a silent
  miscompile, never a guess.
- **Diagnostic codes are stable and never reused.** New codes go in
  the owning spec's table, the catalog (`q64/src/parser/diag.zig`),
  and — when emitted — a `spec/tests/` fixture plus the
  `spec/tests/INDEX.md` row.
- **Naming and casing carry meaning.** `Q64` vs `q64`, `Qube` vs
  `qube`, the Continuum: see [`CLAUDE.md`](./CLAUDE.md).
- **Never commit identity or infrastructure values.** No tokens, no
  account ids, no account emails, no resource ids — placeholders and
  untracked files only. Full rule in
  [`CLAUDE.md` §"Secrets, identity, and audience"](./CLAUDE.md).
- **Leave a trail.** Done work gets a terse entry in
  [`todo.md`](./todo.md); long context belongs in the spec or commit
  message, not the tracker.

## Where to start

[`todo.md`](./todo.md) is the live tracker — the ladder sections at the
top are ordered, sized, and state their definition of done. Unchecked
rungs are the invitation.
