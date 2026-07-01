//! config-read — the minimal `env.config` example, emitted as a WebAssembly component.
//!
//! `read()` fetches a config/secret value by key (returning its byte length, or
//! a sentinel when unset). It goes through `env.config` — the read-only
//! configuration capability — which lowers to an import of `wasi:config/store`
//! when emitted as a component (spec/env.md §`env.config`).
//!
//! Build (the component path):
//!
//!   qube build --component --addr wasm32
//!   wasm-tools component wit …/config-read.component.wasm
//!   # → world imports wasi:config/store, exports read/missing
//!
//! Proves: a capability face lowers to a real WASI **import**. Unlike env.kv /
//! env.blob / env.db (which open a host-held bucket/connection), `get` is a
//! TOP-LEVEL `wasi:config/store` function — the host scopes config to the qube's
//! identity itself, so there is no handle and no `open`. This is the real
//! `wasi:config` proposal, not a q64-owned interface.
//!
//! v0 SCOPE: `get` (a single value by key). `get_all` (the whole config as a
//! list of pairs) is deferred — it returns a variable-length `list<tuple<…>>`
//! that needs the same variable-length typed decode as db's typed Rows, which
//! q64 does not yet emit.

// Read the "greeting" config value; return its byte length, -1 if unset, -2 on error.
pub fn read() -> i64 {
    match env.config.get("greeting") {
        Ok(Some(v)) -> v.len
        Ok(None)    -> 0 - 1
        Err(_)      -> 0 - 2
    }
}

// Read an unset key — exercises the Ok(None) path.
pub fn missing() -> i64 {
    match env.config.get("nope") {
        Ok(Some(v)) -> v.len
        Ok(None)    -> 0 - 1
        Err(_)      -> 0 - 2
    }
}
