# Vendored WIT — capability targets

These `.wit` packages are the **real WASI interface definitions** a q64 qube's
capability faces (`spec/env.md`) lower to when emitted as a component. They are
build inputs, not documentation: `q64 emit --component` writes the synthesized
world plus these dep packages to a temp dir and shells out to
`wasm-tools component embed … && wasm-tools component new` (the same shape as the
`wasi:cli/run` adapter path for `env.out`).

| File | Package | Face | Interfaces used |
|------|---------|------|-----------------|
| `wasi-keyvalue.wit` | `wasi:keyvalue@0.2.0-draft2` | `env.kv` | `store` (`open`), `atomics` (`increment`) |

## Provenance

`wasi-keyvalue.wit` is `wit/store.wit` + `wit/atomic.wit` from
[WebAssembly/wasi-keyvalue](https://github.com/WebAssembly/wasi-keyvalue),
concatenated under one `package wasi:keyvalue@0.2.0-draft2;` header (the upstream
files carry no header — the package is declared in the upstream `world.wit`,
which we don't need). The `batch` and `watcher` interfaces are omitted: `env.kv`
reaches only `store` + `atomics` (`spec/env.md` §"Face method ↔ WIT function
mapping"). Pinned at `0.2.0-draft2`; the version is independent of the `wasip3`
core snapshot (`spec/env.md` §`env.kv`), so it is bumped here deliberately, not
with the core WASI pin.

## Why committed, not init.sh-vendored

The other `vendor/` inputs (the `wasm-tools` binary, the preview1 adapter) are
large and platform-specific, so `init.sh` fetches them sha256-pinned. This WIT is
~9 KB of stable text and is needed at every component emit, so it is committed
and `@embedFile`d straight into the q64 binary — no network, no init step, fully
deterministic.
