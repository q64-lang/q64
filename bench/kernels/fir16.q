//! bench: fir16 — a 16-tap FIR over a scalar shift register, driven by a
//! naive saw. Sixteen mul-adds plus fifteen register moves per sample; the
//! fully-unrolled convolution shape SIMD and (later) the optimizer should
//! collapse.

fn pass(n: i64) -> f64 {
    var ph = f32(0.0)
    let inc = f32(0.010986)
    let one = f32(1.0)
    let two = f32(2.0)
    let c0 = f32(0.003)
    let c1 = f32(0.009)
    let c2 = f32(0.021)
    let c3 = f32(0.041)
    let c4 = f32(0.066)
    let c5 = f32(0.092)
    let c6 = f32(0.113)
    let c7 = f32(0.125)
    let c8 = f32(0.125)
    let c9 = f32(0.113)
    let c10 = f32(0.092)
    let c11 = f32(0.066)
    let c12 = f32(0.041)
    let c13 = f32(0.021)
    let c14 = f32(0.009)
    let c15 = f32(0.003)
    var x0 = f32(0.0)
    var x1 = f32(0.0)
    var x2 = f32(0.0)
    var x3 = f32(0.0)
    var x4 = f32(0.0)
    var x5 = f32(0.0)
    var x6 = f32(0.0)
    var x7 = f32(0.0)
    var x8 = f32(0.0)
    var x9 = f32(0.0)
    var x10 = f32(0.0)
    var x11 = f32(0.0)
    var x12 = f32(0.0)
    var x13 = f32(0.0)
    var x14 = f32(0.0)
    var x15 = f32(0.0)
    var acc = f32(0.0)
    var i = 0
    while i < n {
        ph = ph + inc
        if ph > one { ph = ph - two }
        x15 = x14
        x14 = x13
        x13 = x12
        x12 = x11
        x11 = x10
        x10 = x9
        x9 = x8
        x8 = x7
        x7 = x6
        x6 = x5
        x5 = x4
        x4 = x3
        x3 = x2
        x2 = x1
        x1 = x0
        x0 = ph
        var y = c0 * x0 + c1 * x1 + c2 * x2 + c3 * x3
        y = y + c4 * x4 + c5 * x5 + c6 * x6 + c7 * x7
        y = y + c8 * x8 + c9 * x9 + c10 * x10 + c11 * x11
        y = y + c12 * x12 + c13 * x13 + c14 * x14 + c15 * x15
        acc = acc + y
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
    env.out("bench fir16 samples {n} ns {best} check {check}")
}
