# `env.kv` → `wasi:keyvalue` component lowering — design of record

A qube that reaches `env.kv` (the key-value capability, `spec/env.md`) emits a
component that **imports** `wasi:keyvalue/{store, atomics}` and lets the host
supply them. This directory pins the exact lowering, proven end-to-end through
`wasm-tools`, independent of the q64 build:

- **`reference-core.wat`** — the byte-exact core module `q64 emit --component`
  must produce. Header comments document the canonical-ABI facts (import naming,
  result memory layout, the adapter-held bucket). This is the oracle the Binaryen
  codegen targets.
- **`world.wit`** — the synthesized world: `env.kv` → two `import`s, the public
  `bump` fn → one `export`. q64 generates the equivalent from the qube's surface.
- **`wasi-keyvalue.wit`** — the vendored `wasi:keyvalue@0.2.0-draft2` dep package
  (copy of `src/codegen/wit/wasi-keyvalue.wit`, kept local so `run.sh` is
  self-contained).
- **`run.sh`** — assembles the *reference* core, embeds the world + dep, lifts to
  a component, validates it, and asserts the component WIT imports real
  `wasi:keyvalue` and exports `bump`.
- **`verify-q64.sh`** — the same, but on the **real** `q64 emit --component`
  output for `examples/kv-counter` (build q64 first). When `node` + `jco` are
  available it also transpiles the component and runs `bump`/`read` against a
  generic `wasi:keyvalue` host (`host.mjs`) — proving the canonical-ABI glue at
  runtime, not just structurally.
- **`host.mjs`** — a stock `wasi:keyvalue` JS host (an in-memory store) that
  drives the transpiled component. Its imports are the plain WASI interfaces (no
  q64-specific ABI) — the same role the qubepods Dynamic Worker host plays.

## The lowering, in one breath

`env.kv.increment("count", 1)` in q64 source becomes, in the core:

1. **lazy open** — the first `env.kv` use calls `store.open` with an *empty*
   identifier; the host pins the returned bucket to the qube's identity
   (qubepods: `org/project/app`). The handle is cached in a module global, so the
   qube never re-opens and never names a namespace.
2. **increment** — `atomics.increment(bucket, "count", 1)` writes
   `result<s64, error>` into a return area; the core reads the discriminant and,
   on `ok`, the `s64` total.

The `store.open` step being the host's — not the qube's — is what makes the
capability multi-tenant: the qube's code is identical for every tenant; identity
is bound by the adapter at `open`. See `spec/env.md` §`env.kv`.

## Why this is not the local `qube run` shape

`qube run` instantiates the *same* qube on the vendored wasmtime host, which
serves q64's raw `env.*` faces (`env.kv_increment`) directly — no component lift.
The `cm32p2|wasi:keyvalue/...` imports here are the **component** core ABI, a
distinct lowering selected only on the `--component` path (parallel to how
`env.out` emits a `wasi_snapshot_preview1.fd_write` core for the `wasi:cli/run`
adapter instead of `env.out`). One source, two core ABIs, picked by target.
