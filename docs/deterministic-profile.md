# The deterministic profile — record/replay as a compiler property

Status: design note (2026-07), per `docs/language-analysis-2026-07.md` §4
(world models / digital twins). First piece already shipped: the wasmtime
host's `Q64_SEED` (see `env.random_u64` in `runtime/wasmtime/src/main.zig`).

## The observation

q64 programs are deterministic by construction **except** where a
capability lets the world in. There is no ambient clock, no ambient RNG,
no hidden I/O — `env.time.*`, `env.random.*`, `env.net.*`, `env.fs.*` are
the complete list of nondeterminism entry points, and the effect pass
already computes exactly which of them a program reaches. So deterministic
replay is not a language feature to add; it is a **host policy** over a
boundary the compiler already proves.

## The profile

`qube run --deterministic` (equivalently a `[profile.deterministic]`
manifest block) configures the host, not the program:

- **`env.random`** — seeded stream (`Q64_SEED`); **shipped**.
- **`env.time`** — virtual clock: starts at a fixed epoch, advances only
  on `sleep_ns` (by the requested amount) and scheduler ticks, never by
  wall time. Two runs see identical timestamps.
- **`env.net` / `env.fs` / `env.kv` …** — record/replay: first run
  captures each capability call's result into a log; replay serves the
  log and **traps on divergence** (a request the log doesn't contain).
- The capability set (`q64 show capabilities`) is the complete manifest
  of what the log must cover — nothing else can observe the world.

## Why arenas make snapshot/rollback cheap

The complementary primitive for what-if simulation: program state at a
tick boundary is (linear memory watermarks + globals + the scope arena
contents). Because regions are bump arenas with known bases and
watermarks, `snapshot()` is a bounded memcpy and `restore()` is the
reverse — no object graph traversal, no GC cooperation. Sequencing: after
named regions land; the snapshot verbs belong on the region value
(`spec/memory.md`'s vocabulary), host-assisted for the wasm instance's
memory pages.

## What this buys, concretely

Reproducible test runs of effectful code without mocks; bit-identical
simulation replays (world models, game servers — the quine engine's
fixed-timestep rule, as a language-level guarantee); time-travel debugging
of twins (replay the log to tick N, snapshot, branch). All of it falls
out of two things q64 already has: capabilities as the only world
boundary, and the effect pass as the auditor of that boundary.
