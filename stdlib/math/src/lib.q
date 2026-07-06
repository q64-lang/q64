//! q64.math — scalar floating-point math.
//!
//! The design split this module embodies:
//!
//!   * **Hardware primitives** (`abs`, `sqrt`, `floor`, `ceil`, `trunc`,
//!     `round`) are each a single Wasm instruction. The compiler already
//!     spells them as f64 methods — `x.sqrt()`, `x.floor()`, `x.nearest()`
//!     (see `q64/src/ir/ops.zig` `UnKind` → `q64/src/codegen/emit.zig`). This
//!     module only re-exports them as free functions for a uniform surface.
//!
//!   * **Transcendentals** (`exp`, `sin`, `cos`, `tanh`) have no Wasm opcode,
//!     so they are software: range reduction + a polynomial, i.e. nothing but
//!     f64 arithmetic. They live here, in pure q64 — no codegen change is
//!     needed to build this qube.
//!
//! Accuracy target is ~1e-9 over the argument ranges an audio-DSP kernel uses
//! (waveform phase, a diode exponent, a soft-clip). This is not a full libm:
//! `ln`/`pow`/`atan` and the f32 variants are deliberately deferred until a
//! consumer pulls them.

// π and friends, to full f64 precision.
let PI      = 3.141592653589793
let HALF_PI = 1.5707963267948966
let TWO_PI  = 6.283185307179586
let INV_2PI = 0.15915494309189535
let LN2     = 0.6931471805599453
let INV_LN2 = 1.4426950408889634

// --- hardware primitives (one Wasm instruction each) -----------------------

pub fn abs(x: f64)   -> f64 { x.abs() }
pub fn sqrt(x: f64)  -> f64 { x.sqrt() }
pub fn floor(x: f64) -> f64 { x.floor() }
pub fn ceil(x: f64)  -> f64 { x.ceil() }
pub fn trunc(x: f64) -> f64 { x.trunc() }

// Round half-to-even (Wasm `nearest`) — the rounding range reduction wants.
pub fn round(x: f64) -> f64 { x.nearest() }

// --- exp -------------------------------------------------------------------

// exp(r) for |r| <= ln2/2, via an 8-term Taylor series in Horner form.
fn exp_small(r: f64) -> f64 {
    var p = 1.0 / 5040.0
    p = p * r + 1.0 / 720.0
    p = p * r + 1.0 / 120.0
    p = p * r + 1.0 / 24.0
    p = p * r + 1.0 / 6.0
    p = p * r + 0.5
    p = p * r + 1.0
    p = p * r + 1.0
    p
}

// 2^k for an integer-valued k, by repeated doubling/halving. k stays an f64
// throughout, so no int<->float conversion is required.
fn pow2i(k: f64) -> f64 {
    var e = k
    var acc = 1.0
    while e > 0.5  { acc = acc * 2.0; e = e - 1.0 }
    while e < -0.5 { acc = acc * 0.5; e = e + 1.0 }
    acc
}

// exp(x) = 2^k · exp(r), with x = k·ln2 + r and |r| <= ln2/2.
pub fn exp(x: f64) -> f64 {
    let scaled = x * INV_LN2
    let k = scaled.nearest()
    let r = x - k * LN2
    exp_small(r) * pow2i(k)
}

// --- sin / cos -------------------------------------------------------------

// sin(t) for |t| <= π/2, via a 6-term odd Taylor series in Horner form (u = t²).
fn sin_small(t: f64) -> f64 {
    let u = t * t
    var p = -1.0 / 39916800.0
    p = p * u + 1.0 / 362880.0
    p = p * u - 1.0 / 5040.0
    p = p * u + 1.0 / 120.0
    p = p * u - 1.0 / 6.0
    p = p * u + 1.0
    t * p
}

pub fn sin(x: f64) -> f64 {
    // Reduce to [-π, π], then fold into [-π/2, π/2] (sin-preserving).
    let turns = x * INV_2PI
    let k = turns.nearest()
    var t = x - TWO_PI * k
    if t > HALF_PI  { t = PI - t }
    if t < -HALF_PI { t = -PI - t }
    sin_small(t)
}

pub fn cos(x: f64) -> f64 { sin(x + HALF_PI) }

// --- tanh ------------------------------------------------------------------

// tanh(x) = (e^{2x} − 1)/(e^{2x} + 1), clamped where it saturates f64 anyway.
pub fn tanh(x: f64) -> f64 {
    if x >  20.0 { return  1.0 }
    if x < -20.0 { return -1.0 }
    let e = exp(x + x)
    (e - 1.0) / (e + 1.0)
}
