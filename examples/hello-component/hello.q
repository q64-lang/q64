//! hello-component — the minimal example, emitted as a WebAssembly component.
//!
//! Identical source to examples/hello; the difference is in qube.json5,
//! which sets component.emit so the build wraps the core module in a
//! component targeting the wasi:cli/command world.
//!
//! Build + run (Slice A of the spec/ verification ladder):
//!
//!   qube build --component                 # → target/<host>/hello-component.{wasm,component.wasm}
//!   wasmtime run target/<host>/hello-component.component.wasm
//!   # → Hello, q64.
//!
//! Proves: core-module embedding + one capability-import lift
//! (@stdout → wasi:cli/stdout), with the core module still produced.
//! See spec/modules.md §"The qube as a component" and spec/env.md
//! §"Env ↔ WASI Preview 2".

fn main {
    env.out("Hello, q64.")
}
