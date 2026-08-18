//! bench: gain_buf_simd4 — the gain_buf loop four lanes at a time via
//! Simd.load / x.store over the same 1024-sample Vec<f32>. One bounds
//! check per group of four instead of two per sample; identical math, so
//! the checksum must match gain_buf exactly.

fn main {
    let block = 1024
    let sweeps = 2000
    let samples = block * sweeps
    var v: Vec<f32> = Vec.new()
    var f = 0
    while f < block {
        v.push(f32(1.0))
        f = f + 1
    }
    let g = Simd.splat(f32(0.9995))
    var best = 999999999999
    var check = 0.0
    var rep = 0
    while rep < 7 {
        // Refill outside the timed region so every rep decays from 1.0 —
        // matches the Rust twin, which rebuilds its buffer per call.
        var r = 0
        while r < block {
            v[r] = f32(1.0)
            r = r + 1
        }
        let t0 = env.time.monotonic_ns()
        var s = 0
        while s < sweeps {
            var i = 0
            while i < block {
                var x = Simd.load(v, i)
                x = x.mul(g)
                x.store(v, i)
                i = i + 4
            }
            s = s + 1
        }
        let t1 = env.time.monotonic_ns()
        let dt = t1 - t0
        if dt < best { best = dt }
        let a = v[0]
        let z = v[1023]
        check = f64(a) + f64(z)
        rep = rep + 1
    }
    env.out("bench gain_buf_simd4 samples {samples} ns {best} check {check}")
}
