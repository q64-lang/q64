//! library — a main-less library qube: only public exports, no entry.
//! Exercises `q64 show world` / `show capabilities` over a pure export surface.

pub fn version() -> str { "0.1.0" }

pub fn add(a: i64, b: i64) -> i64 { a + b }
