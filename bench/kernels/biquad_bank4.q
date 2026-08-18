//! bench: biquad_bank4 — one DF2T biquad over four independent channels in
//! the lanes of Simd<f32, 4>, with the multiply-adds fused via mul_add
//! (relaxed-SIMD madd). Uses the full A3 surface: replace to give each lane
//! its own input level, mul_add chains for the filter core, sub for the
//! feedback terms. Input is a per-lane exponential decay (no branches).
//! One loop iteration is four samples, so `samples` reports 4·n.
//!
//! The negated feedback coefficients (na1 = -a1, na2 = -a2) turn the DF2T
//! update into pure fused chains:  y = b0·x + s1;  s1 = na1·y + (b1·x + s2);
//! s2 = na2·y + b2·x.

fn pass(n: i64) -> f64 @realtime {
    let b0 = Simd.splat(f32(0.000944692))
    let b1 = Simd.splat(f32(0.001889384))
    let b2 = Simd.splat(f32(0.000944692))
    let na1 = Simd.splat(f32(1.911196288))
    let na2 = Simd.splat(f32(-0.914975055))
    var x = Simd.splat(f32(1.0))
    var x1 = x.replace(1, f32(0.8))
    x1 = x1.replace(2, f32(0.6))
    x = x1.replace(3, f32(0.4))
    let r = Simd.splat(f32(0.9999995))
    var s1 = Simd.splat(f32(0.0))
    var s2 = Simd.splat(f32(0.0))
    var acc = Simd.splat(f32(0.0))
    var i = 0
    while i < n {
        x = x.mul(r)
        let y = b0.mul_add(x, s1)
        let t = b1.mul_add(x, s2)
        s1 = na1.mul_add(y, t)
        s2 = na2.mul_add(y, b2.mul(x))
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
    env.out("bench biquad_bank4 samples {samples} ns {best} check {check}")
}
