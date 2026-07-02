//! time-mono — the minimal `env.time` example, emitted as a WebAssembly component.
//!
//! `mono()` reads the monotonic clock in nanoseconds; `delta()` reads it twice
//! and returns the elapsed span (never negative — the clock is monotonic). Both
//! go through `env.time` — the clock capability — which lowers to an import of
//! `wasi:clocks/monotonic-clock` when emitted as a component (spec/env.md
//! §`env.time`).
//!
//! Build (the component path):
//!
//!   qube build --component --addr wasm32
//!   wasm-tools component wit …/time-mono.component.wasm
//!   # → world imports wasi:clocks/monotonic-clock, exports mono/delta
//!
//! Proves: the one bare-scalar capability face. `monotonic_ns()` is nullary and
//! returns a plain i64 — no Result box, no return area, no realloc — which is
//! why it is `@realtime`-safe (spec/env.md §"realtime"). The local (non-
//! component) build imports the raw `env.monotonic_ns` host face instead.

// The monotonic clock reading, in nanoseconds since an arbitrary origin.
pub fn mono() -> i64 { env.time.monotonic_ns() }

// The span between two consecutive readings, in nanoseconds (>= 0).
pub fn delta() -> i64 {
    let a = env.time.monotonic_ns()
    let b = env.time.monotonic_ns()
    b - a
}
