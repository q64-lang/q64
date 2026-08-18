//! q64.audio — DSP building blocks (v1).
//!
//! exports: one_pole, biquad, saw, delay_tick, denormal_flush, clamp1,
//!          soft_clip, tanh_fast, Tick, Gen
//!
//! Everything is f32 — the canonical audio bus format — and every
//! per-sample path is `@realtime` (free functions checked by `q64 check`;
//! fit-method bodies follow the same discipline by construction: no
//! allocation, no capability use, no panic).
//!
//! The v1 shape: stateful processors are structs created by constructor
//! functions (`one_pole(a)`, `biquad(…)`, `saw(inc)`) and driven by fit
//! methods — `p.tick(x)` for processors, `o.next()` for generators.
//! Consumers import the constructors; the struct types stay internal to
//! the call (v0 cross-module struct-name imports are not resolved yet).
//! Coefficients are taken precomputed: the design helpers that need
//! transcendentals (`lowpass_coeffs(fc, sr)`, `db_to_gain`) arrive when
//! `q64.audio` can depend on `q64.math`'s f32 tier.

// ---------------------------------------------------------------------
// Faces — the two per-sample shapes.
// ---------------------------------------------------------------------

/// A processor: one sample in, one sample out, internal state advances.
pub face Tick {
    fn tick(self, x: f32) -> f32
}

/// A generator: no input, one sample out per call.
pub face Gen {
    fn next(self) -> f32
}

// ---------------------------------------------------------------------
// Utilities.
// ---------------------------------------------------------------------

/// Flush a value in the denormal range to exactly zero. Wasm has no
/// FTZ/DAZ mode: a filter state decaying toward zero eventually produces
/// denormal f32s, which many engines execute orders of magnitude slower.
/// Every recursive state update in this library runs through this; user
/// filters should do the same.
pub fn denormal_flush(x: f32) -> f32 @realtime {
    if x < f32(0.000000000000000001) {
        if x > f32(-0.000000000000000001) {
            return f32(0.0)
        }
    }
    x
}

/// Hard clamp to the bus range [-1, 1].
pub fn clamp1(x: f32) -> f32 @realtime {
    var y = x
    if y > f32(1.0) { y = f32(1.0) }
    if y < f32(-1.0) { y = f32(-1.0) }
    y
}

/// Cubic soft clipper: y = 1.5x − 0.5x³ inside the knee, hard-clamped
/// outside. The classic cheap saturation curve.
pub fn soft_clip(x: f32) -> f32 @realtime {
    if x > f32(1.0) { return f32(1.0) }
    if x < f32(-1.0) { return f32(-1.0) }
    x * (f32(1.5) - f32(0.5) * x * x)
}

/// Fast tanh via the (3,2) Padé approximant x·(27 + x²) / (27 + 9x²),
/// clamped to ±1 outside |x| ≤ 3 where the approximation leaves the
/// curve. Max error ≈ 2% (near |x| ≈ 1–3) — inaudible as a saturation
/// curve, and a few muls instead of a transcendental call.
pub fn tanh_fast(x: f32) -> f32 @realtime {
    if x > f32(3.0) { return f32(1.0) }
    if x < f32(-3.0) { return f32(-1.0) }
    let x2 = x * x
    x * (f32(27.0) + x2) / (f32(27.0) + f32(9.0) * x2)
}

// ---------------------------------------------------------------------
// One-pole smoother — the parameter-smoothing workhorse.
// ---------------------------------------------------------------------

pub struct OnePole {
    a: f32,
    y: f32,
}

/// A one-pole lowpass `y += a·(x − y)`. `a` in (0, 1]: small = slow.
/// The standard click-free parameter smoother.
pub fn one_pole(a: f32) -> OnePole {
    OnePole { a: a, y: f32(0.0) }
}

pub fit OnePole : Tick {
    fn tick(self, x: f32) -> f32 {
        self.y = denormal_flush(self.y + self.a * (x - self.y))
        self.y
    }
}

// ---------------------------------------------------------------------
// Biquad — direct form II transposed, the canonical second-order section.
// ---------------------------------------------------------------------

pub struct Biquad {
    b0: f32,
    b1: f32,
    b2: f32,
    a1: f32,
    a2: f32,
    s1: f32,
    s2: f32,
}

/// A DF2T biquad from precomputed coefficients (normalized, a0 = 1).
pub fn biquad(b0: f32, b1: f32, b2: f32, a1: f32, a2: f32) -> Biquad {
    Biquad { b0: b0, b1: b1, b2: b2, a1: a1, a2: a2, s1: f32(0.0), s2: f32(0.0) }
}

pub fit Biquad : Tick {
    fn tick(self, x: f32) -> f32 {
        let y = self.b0 * x + self.s1
        self.s1 = denormal_flush(self.b1 * x - self.a1 * y + self.s2)
        self.s2 = denormal_flush(self.b2 * x - self.a2 * y)
        y
    }
}

// ---------------------------------------------------------------------
// Saw oscillator — naive phase accumulator.
// ---------------------------------------------------------------------

pub struct SawOsc {
    ph: f32,
    inc: f32,
}

/// A naive (aliasing) sawtooth in [-1, 1). `inc` = 2·freq/sample_rate.
/// Fine for LFOs and tests; the band-limited (poly-BLEP) form is v2.
pub fn saw(inc: f32) -> SawOsc {
    SawOsc { ph: f32(0.0), inc: inc }
}

pub fit SawOsc : Gen {
    fn next(self) -> f32 {
        self.ph = self.ph + self.inc
        if self.ph > f32(1.0) {
            self.ph = self.ph - f32(2.0)
        }
        self.ph
    }
}

// ---------------------------------------------------------------------
// Delay line — over a caller-owned buffer (no allocation in here).
// ---------------------------------------------------------------------

/// One delay-line step over a caller-owned buffer: returns the oldest
/// sample (`buf[idx]`) and writes `x` in its place. The caller owns the
/// buffer (its length is the delay in samples) and advances `idx` by 1
/// per sample, wrapping to 0 at the buffer length.
pub fn delay_tick(out buf: Vec<f32>, idx: i64, x: f32) -> f32 @realtime {
    let old = buf[idx]
    buf[idx] = x
    old
}
