//! bench: mac_simd4 — the mac_f32 recurrence on Simd<f32, 4>, four lanes at
//! once. One loop iteration processes four samples, so `samples` reports 4·n.
//! Directly measures the Simd speedup over mac_f32 on identical math.

fn pass(n: i64) -> f64 {
    var acc = Simd.splat(f32(0.0))
    var x = Simd.splat(f32(1.0))
    let r = Simd.splat(f32(0.9999995))
    let g = Simd.splat(f32(0.5))
    var i = 0
    while i < n {
        acc = acc.add(x.mul(g))
        x = x.mul(r)
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
    env.out("bench mac_simd4 samples {samples} ns {best} check {check}")
}
