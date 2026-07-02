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
| `q64-blob.wit` | `q64:blob@0.2.0-draft2` | `env.blob` | `store` (`open`, bucket methods) |
| `q64-db.wit` | `q64:db@0.2.0-draft2` | `env.db` | `sql` (`open`, connection methods) |
| `wasi-config.wit` | `wasi:config@0.2.0-draft` | `env.config` | `store` (`get`) |
| `wasi-clocks.wit` | `wasi:clocks@0.2.0` | `env.time` | `monotonic-clock` (`now`, `resolution`, `subscribe-duration`), `wall-clock` (`now`) |
| `wasi-io.wit` | `wasi:io@0.2.0` | `env.time.sleep_ns` | `poll` (`pollable.block`, drop) |

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

`wasi-clocks.wit` is the `monotonic-clock` interface from
[WebAssembly/wasi-clocks](https://github.com/WebAssembly/wasi-clocks) at the
stable `0.2.0` release, trimmed to `now` + `resolution`: the upstream interface
also carries `subscribe-instant` / `subscribe-duration`, which pull in
`wasi:io/poll` — q64 does not emit those, and the dep must parse standalone.
Note the version pin is **stable** (no `-draft` tag), which changes the core
import mangling: wit-component keys a stable interface by its semver-compatible
`major.minor` (`cm32p2|wasi:clocks/monotonic-clock@0.2`), unlike the draft pins
above, which are matched verbatim (see `clocks_monotonic_core_mod` in emit.zig).

## Why committed, not init.sh-vendored

The other `vendor/` inputs (the `wasm-tools` binary, the preview1 adapter) are
large and platform-specific, so `init.sh` fetches them sha256-pinned. This WIT is
~9 KB of stable text and is needed at every component emit, so it is committed
and `@embedFile`d straight into the q64 binary — no network, no init step, fully
deterministic.
