//! bench: process_buf — the canonical plugin process signature: an
//! out-of-place block gain through a real function boundary,
//! `fn process(inp: Vec<f32>, out outp: Vec<f32>, …) @realtime` (roadmap
//! phase B3: caller-provided buffers, the `out` parameter mode, checked
//! allocation-free). One call processes a 1024-sample block; a pass makes
//! 2000 calls = 2,048,000 samples — so the per-call overhead (the frame
//! watermark, the argument plumbing) is measured too, exactly as a host
//! calling a plugin's process() would pay it.

fn process(inp: Vec<f32>, out outp: Vec<f32>, g: f32, n: i64) @realtime {
    var i = 0
    while i < n {
        outp[i] = inp[i] * g
        i = i + 1
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
    env.out("bench process_buf samples {samples} ns {best} check {check}")
}
