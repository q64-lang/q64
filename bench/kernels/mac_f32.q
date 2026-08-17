//! bench: mac_f32 — scalar f32 multiply-accumulate with a decay recurrence.
//!
//! The floor for every other kernel: one mul-add and one mul per sample, no
//! branches, no memory. The decay ratio keeps `x` well above the denormal
//! range at the chosen sample count.

fn pass(n: i64) -> f64 {
    var acc = f32(0.0)
    var x = f32(1.0)
    let r = f32(0.9999995)
    let g = f32(0.5)
    var i = 0
    while i < n {
        acc = acc + x * g
        x = x * r
        i = i + 1
    }
    f64(acc)
}

fn main {
    let n = 4000000
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
    env.out("bench mac_f32 samples {n} ns {best} check {check}")
}
