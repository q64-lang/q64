//! dev.q64.hello_app — links dev.q64.hello_world and prints its version.
//!
//! The definition of done for the compiler's linking ladder (todo.md):
//! this program prints `0.1.0` by calling the dependency's `version()`.
//!
//! Compile + run directly:
//!
//!   q64 emit src/main.q /tmp/app.wasm \
//!     --module dev.q64.hello_world=../hello_world/src
//!   runtime/wasmtime/zig-out/bin/q64-wasmtime-host /tmp/app.wasm
//!
//! Or via the end-to-end smoke test:
//!
//!   ./scripts/link-roundtrip.sh

import dev.q64.hello_world.{version}

fn main {
    env.out(version())
}
