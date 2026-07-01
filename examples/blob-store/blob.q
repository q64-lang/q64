//! blob-store — the minimal `env.blob` example, emitted as a WebAssembly component.
//!
//! `save()` writes an object, `read()` reads it back (its byte length, or a
//! sentinel when absent), `drop()` deletes it. All go through `env.blob` — the
//! object-store capability — which lowers to imports of `q64:blob/store` when
//! emitted as a component (spec/env.md §`env.blob`).
//!
//! Build (the component path):
//!
//!   qube build --component --addr wasm32
//!   wasm-tools component wit …/blob-store.component.wasm
//!   # → world imports q64:blob/store, exports save/read/drop
//!
//! Proves: a capability face lowers to a real host **import**. The bucket is
//! host-opened and identity-pinned (org/project/app on qubepods), so this same
//! source is multi-tenant with no namespace in it — exactly like `env.kv`.
//! `env.blob` targets a q64-owned `q64:blob/store` (flat `list<u8>` in/out), not
//! raw `wasi:blobstore`: blobstore's write path is stream-only (wasi:io), which
//! q64 codegen does not yet emit; the host does any real streaming internally.
//! The exact lowering is pinned in test/blob-component-reference/.

// Store "hello" under the key "greeting"; return 1 on success, 0 on error.
pub fn save() -> i64 {
    match env.blob.put("greeting", "hello") {
        Ok(())  -> 1
        Err(_)  -> 0
    }
}

// Read the object back: its byte length when present, -1 when absent, -2 on error.
pub fn read() -> i64 {
    match env.blob.get("greeting") {
        Ok(Some(v)) -> v.len
        Ok(None)    -> 0 - 1
        Err(_)      -> 0 - 2
    }
}

// Delete the object (idempotent); return 1 on success, 0 on error.
pub fn drop() -> i64 {
    match env.blob.delete("greeting") {
        Ok(())  -> 1
        Err(_)  -> 0
    }
}
