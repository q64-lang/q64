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
//! Proves: env.out is lowered to a WASI preview1 `fd_write` import (writing an
//! iovec to fd 1), and `wasm-tools component new --adapt` (with the vendored
//! WASI adapter) lifts that preview1 core into a real `wasi:cli/run` command
//! that imports `wasi:cli/stdout` — the same world `q64 show world` names. The
//! core module is still produced. wasm32-only for now (preview1 is 32-bit).
//! See spec/modules.md §"The qube as a component" and spec/env.md
//! §"Env ↔ WASI Preview 3".

fn main {
    env.out("Hello, q64.")
}
