//! hello — minimal q64 example.
//!
//! Compile + run with:
//!
//!   q64 emit examples/hello/hello.q /tmp/hello.wasm
//!   runtime/wasmtime/zig-out/bin/q64-wasmtime-host /tmp/hello.wasm
//!
//! Or via the end-to-end smoke test:
//!
//!   ./scripts/hello-roundtrip.sh

fn main {
    env.out("Hello, q64.")
}
