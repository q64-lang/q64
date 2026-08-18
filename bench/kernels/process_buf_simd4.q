//! bench: process_buf_simd4 — process_buf four lanes at a time:
//! `Simd.load` from the input parameter buffer, `x.store` into the `out`
//! parameter buffer. The vectorized plugin process shape, still a checked
//! `@realtime` function boundary per block.

fn process(inp: Vec<f32>, out outp: Vec<f32>, gs: f32, n: i64) @realtime {
    let g = Simd.splat(gs)
    var i = 0
    while i < n {
        var x = Simd.load(inp, i)
        x = x.mul(g)
        x.store(outp, i)
        i = i + 4
    }
}

fn main {
    let block = 1024
    let sweeps = 2000
    let samples = block * sweeps
    var inp: Vec<f32> = Vec.new()
    var outp: Vec<f32> = Vec.new()
    var f = 0
    while f < block {
        inp.push(f32(1.0))
        outp.push(f32(0.0))
        f = f + 1
    }
    let g = f32(0.9995)
    var best = 999999999999
    var check = 0.0
    var rep = 0
    while rep < 7 {
        let t0 = env.time.monotonic_ns()
        var s = 0
        while s < sweeps {
            process(inp, outp, g, block)
            s = s + 1
        }
        let t1 = env.time.monotonic_ns()
        let dt = t1 - t0
        if dt < best { best = dt }
        let a = outp[0]
        let z = outp[1023]
        check = f64(a) + f64(z)
        rep = rep + 1
    }
    env.out("bench process_buf_simd4 samples {samples} ns {best} check {check}")
}
