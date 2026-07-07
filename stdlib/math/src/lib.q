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
//!   * **Transcendentals** (`exp`, `sin`, `cos`, `tanh`, `ln`, `log2`,
//!     `log10`, `pow`, `atan`, `atan2`) have no Wasm opcode, so they are
//!     software: range reduction + a polynomial, i.e. nothing but f64
//!     arithmetic. They live here, in pure q64 — no codegen change is
//!     needed to build this qube.
//!
//! Accuracy target is ~1e-9 over the argument ranges an audio-DSP kernel uses
//! (waveform phase, a diode exponent, a soft-clip). This is not a full libm:
//! the f32 variants and `asin`/`acos` are deferred until a consumer pulls
//! them. Out-of-domain arguments (`ln` of a non-positive) yield NaN, not a
//! trap — the caller checks the domain when it matters.

// π and friends, to full f64 precision.
let PI        = 3.141592653589793
let HALF_PI   = 1.5707963267948966
let TWO_PI    = 6.283185307179586
let INV_2PI   = 0.15915494309189535
let LN2       = 0.6931471805599453
let INV_LN2   = 1.4426950408889634
let INV_LN10  = 0.4342944819032518
let SQRT2     = 1.4142135623730951
let INV_SQRT2 = 0.7071067811865476

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

// --- ln / log2 / log10 ------------------------------------------------------

// ln(m) for m in [1/√2, √2], via the atanh series: with t = (m−1)/(m+1),
// ln(m) = 2·(t + t³/3 + t⁵/5 + …). |t| ≤ 0.1716 there, so eight odd terms
// land near 1e-13 — comfortably past the module's accuracy target.
fn ln_core(m: f64) -> f64 {
    let t = (m - 1.0) / (m + 1.0)
    let u = t * t
    var p = 1.0 / 15.0
    p = p * u + 1.0 / 13.0
    p = p * u + 1.0 / 11.0
    p = p * u + 1.0 / 9.0
    p = p * u + 1.0 / 7.0
    p = p * u + 1.0 / 5.0
    p = p * u + 1.0 / 3.0
    p = p * u + 1.0
    2.0 * t * p
}

// ln(x) for x > 0: normalize x = m · 2^k with m in [1/√2, √2) by repeated
// doubling/halving (k stays an f64, like `pow2i` — no int↔float conversion),
// then ln(x) = ln(m) + k·ln2. A non-positive x yields NaN.
pub fn ln(x: f64) -> f64 {
    if x <= 0.0 {
        let z = x * 0.0
        return z / z            // 0/0 → NaN: ln is undefined here
    }
    var m = x
    var k = 0.0
    while m >= SQRT2     { m = m * 0.5; k = k + 1.0 }
    while m < INV_SQRT2  { m = m + m;   k = k - 1.0 }
    ln_core(m) + k * LN2
}

pub fn log2(x: f64)  -> f64 { ln(x) * INV_LN2 }
pub fn log10(x: f64) -> f64 { ln(x) * INV_LN10 }

// --- pow ---------------------------------------------------------------------

// x^y = exp(y·ln x). Domain: x > 0 (a non-positive base rides ln's NaN);
// y = 0 is 1 for any x, per the usual convention.
pub fn pow(x: f64, y: f64) -> f64 {
    if y == 0.0 { return 1.0 }
    exp(y * ln(x))
}

// --- atan / atan2 -----------------------------------------------------------

// atan(t) for |t| ≤ ~0.1 — reached after four half-angle reductions — via a
// six-term odd Taylor series in Horner form (u = t²).
fn atan_small(t: f64) -> f64 {
    let u = t * t
    var p = -1.0 / 11.0
    p = p * u + 1.0 / 9.0
    p = p * u - 1.0 / 7.0
    p = p * u + 1.0 / 5.0
    p = p * u - 1.0 / 3.0
    p = p * u + 1.0
    t * p
}

// Halve the angle four times — atan(x) = 2·atan(x / (1 + √(1 + x²))) — then
// run the series and double back. Valid for every finite x with no quadrant
// logic: even x → ∞ contracts to |t| ≤ tan(π/32) ≈ 0.0985.
pub fn atan(x: f64) -> f64 {
    var t = x
    var s = 0.0
    var i = 0.0
    while i < 4.0 {
        s = 1.0 + t * t
        t = t / (1.0 + s.sqrt())
        i = i + 1.0
    }
    16.0 * atan_small(t)
}

// atan2(y, x): the angle of the point (x, y), in (−π, π]. atan2(0, 0) is 0
// by the usual convention.
pub fn atan2(y: f64, x: f64) -> f64 {
    if x > 0.0 { return atan(y / x) }
    if x < 0.0 {
        if y >= 0.0 { return atan(y / x) + PI }
        return atan(y / x) - PI
    }
    if y > 0.0 { return HALF_PI }
    if y < 0.0 { return 0.0 - HALF_PI }
    0.0
}
