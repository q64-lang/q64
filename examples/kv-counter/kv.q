//! kv-counter — the minimal `env.kv` example, emitted as a WebAssembly component.
//!
//! `bump()` atomically increments a host-held counter; `read()` reads it back
//! (a +0 increment). Both go through `env.kv` — the key-value capability — which
//! lowers to imports of `wasi:keyvalue/{store, atomics}` when emitted as a
//! component (spec/env.md §`env.kv`).
//!
//! Build (the component path):
//!
//!   qube build --component --addr wasm32   # → target/debug/wasm32/kv-counter.{wasm,component.wasm,wit}
//!   wasm-tools component wit …/kv-counter.component.wasm
//!   # → world imports wasi:keyvalue/store + wasi:keyvalue/atomics, exports bump/read
//!
//! Proves: a capability face lowers to a real WASI **import** the host supplies.
//! The `store.open` step is the host's, not the qube's — the runtime hands
//! `env.kv` already bound to a bucket pinned to the qube's identity (on qubepods:
//! org/project/app), so this same source is multi-tenant with no namespace in it.
//! The exact lowering is pinned in test/kv-component-reference/ (the design of
//! record this codegen targets).

// Atomically add `delta` to the shared "count" key, returning the new total.
// The host always succeeds in v0, so the Result is `Ok(<new total>)`.
fn step(delta: i64) -> i64 {
    match env.kv.increment("count", delta) {
        Ok(n)  -> n
        Err(_) -> 0
    }
}

// Increment the counter by one and return the new total.
pub fn bump() -> i64 {
    step(1)
}

// Read the current total without changing it (a +0 increment).
pub fn read() -> i64 {
    step(0)
}
