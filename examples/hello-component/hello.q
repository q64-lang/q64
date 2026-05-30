//! hello-component — the minimal example, emitted as a WebAssembly component.
//!
//! Identical source to examples/hello; the difference is in qube.json5,
//! which sets component.emit so the build wraps the core module in a
//! component targeting the wasi:cli/command world.
//!
//! Build + run (Slice A of the spec/ verification ladder):
//!
//!   qube build --component --addr wasm32   # → target/debug/wasm32/hello-component.{wasm,component.wasm}
//!   q64-component-check …/hello-component.component.wasm --run
//!   # → Hello, q64.
//!
//! Proves: core-module embedding + one capability-import lowering (env.out →
//! a component `log` import, via the canonical-ABI indirection pattern), with
//! `_start` lifted as `run` and the core module still produced. wasm32-only
//! for now (the 32-bit canonical ABI). Mapping the import to the real
//! `wasi:cli/stdout` interface the synthesized world names is a follow-on.
//! See spec/modules.md §"The qube as a component" and spec/env.md
//! §"Env ↔ WASI Preview 3".

fn main {
    env.out("Hello, q64.")
}
