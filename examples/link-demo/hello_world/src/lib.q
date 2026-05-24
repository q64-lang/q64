//! dev.q64.hello_world — the smallest useful library qube.
//! exports: version

/// The library's version string. A compile-time constant, so a
/// consumer that calls `version()` const-folds it at link time.
pub fn version() -> str { "0.1.0" }
