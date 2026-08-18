//! bench: clip_simd4 — a branch-free cubic soft clipper on Simd<f32, 4>,
//! four voices at once: y = clamp(x·(1.5 − 0.5·x²), −1, 1) via lane-wise
//! min/max instead of softclip's compare branches. Exercises the full v0
//! lane-op surface (mul, sub, min, max, add). The input is a slow
//! exponential swell that crosses the clipping knee mid-pass. One loop
//! iteration is four samples, so `samples` reports 4·n.

fn pass(n: i64) -> f64 @realtime {
    var x = Simd.splat(f32(0.5))
    let growth = Simd.splat(f32(1.0000004))
    let c15 = Simd.splat(f32(1.5))
    let c05 = Simd.splat(f32(0.5))
    let one = Simd.splat(f32(1.0))
    let neg_one = Simd.splat(f32(-1.0))
    var acc = Simd.splat(f32(0.0))
    var i = 0
    while i < n {
        x = x.mul(growth)
        let x2 = x.mul(x)
        let t = c15.sub(x2.mul(c05))
        var y = x.mul(t)
        y = y.min(one)
        y = y.max(neg_one)
        acc = acc.add(y)
        i = i + 1
    }
    f64(acc.extract(0)) + f64(acc.extract(1)) + f64(acc.extract(2)) + f64(acc.extract(3))
}

fn main {
    let n = 1000000
    let samples = n * 4
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
    env.out("bench clip_simd4 samples {samples} ns {best} check {check}")
}
