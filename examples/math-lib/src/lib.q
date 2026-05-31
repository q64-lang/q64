//! dev.q64.math — a scalar library qube, built as a WebAssembly component.
//!
//! Every export is scalar (i64 -> s64), so the component lift wraps them with
//! no capability imports to lower:
//!
//!   qube build --component
//!   # → target/debug/wasm64/dev.q64.math.{wasm,component.wasm}
//!
//! Proves: core-module embedding + canonical-ABI scalar lift, no imports.
//! See spec/modules.md §"The qube as a component".

pub fn add(a: i64, b: i64) -> i64 { a + b }

pub fn mul(a: i64, b: i64) -> i64 { a * b }

pub fn sub(a: i64, b: i64) -> i64 { a - b }
