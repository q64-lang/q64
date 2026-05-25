//! dev.q64.hello_world — the smallest useful library qube.
//! exports: version

/// The library's version string. A consumer that calls `version()`
/// links against this function: codegen emits it as a real wasm
/// function returning `(ptr, len)` and calls it at runtime.
pub fn version() -> str { "0.1.0" }
