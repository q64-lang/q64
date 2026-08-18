//! bench: biquad4 — four cascaded direct-form-II-transposed biquads driven
//! by a naive saw. Coefficients are a 2nd-order Butterworth lowpass at
//! ~1 kHz / 48 kHz. The canonical IIR workload: serial dependency through
//! the filter states, five muls and four adds per stage per sample.
//!
//! The stages are hand-inlined: `ref` parameter mode is not implemented in
//! the v0 emitter yet (ImmutableAssign), so a `stage(x, ref s1, ref s2)`
//! helper can't carry the filter state.

fn pass(n: i64) -> f64 @realtime {
    let b0 = f32(0.000944692)
    let b1 = f32(0.001889384)
    let b2 = f32(0.000944692)
    let a1 = f32(-1.911196288)
    let a2 = f32(0.914975055)
    var ph = f32(0.0)
    let inc = f32(0.010986)
    let one = f32(1.0)
    let two = f32(2.0)
    var s1a = f32(0.0)
    var s2a = f32(0.0)
    var s1b = f32(0.0)
    var s2b = f32(0.0)
    var s1c = f32(0.0)
    var s2c = f32(0.0)
    var s1d = f32(0.0)
    var s2d = f32(0.0)
    var acc = f32(0.0)
    var i = 0
    while i < n {
        ph = ph + inc
        if ph > one { ph = ph - two }
        let y0 = b0 * ph + s1a
        s1a = b1 * ph - a1 * y0 + s2a
        s2a = b2 * ph - a2 * y0
        let y1 = b0 * y0 + s1b
        s1b = b1 * y0 - a1 * y1 + s2b
        s2b = b2 * y0 - a2 * y1
        let y2 = b0 * y1 + s1c
        s1c = b1 * y1 - a1 * y2 + s2c
        s2c = b2 * y1 - a2 * y2
        let y3 = b0 * y2 + s1d
        s1d = b1 * y2 - a1 * y3 + s2d
        s2d = b2 * y2 - a2 * y3
        acc = acc + y3
        i = i + 1
    }
    f64(acc)
}

fn main {
    let n = 1000000
    var best = 999999999999
    var check = 0.0
    var rep = 0
    while rep < 7 {
        let t0 = env.time.monotonic_ns()
        check = pass(n)
        let t1 = env.time.monotonic_ns()
        let dt = t1 - t0
        if dt < best { best = dt }
        rep = rep + 1
    }
    env.out("bench biquad4 samples {n} ns {best} check {check}")
}
