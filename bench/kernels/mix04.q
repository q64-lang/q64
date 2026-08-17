//! bench: mix04 — a 4-channel mix bus. Four naive-saw phase accumulators
//! (each with a wrap branch) scaled by per-channel gains and summed. The
//! shape of a DAW summing loop: adds, muls, and predictable branches.

fn pass(n: i64) -> f64 {
    var p0 = f32(0.0)
    var p1 = f32(0.25)
    var p2 = f32(0.5)
    var p3 = f32(0.75)
    let i0 = f32(0.010986)
    let i1 = f32(0.014648)
    let i2 = f32(0.021973)
    let i3 = f32(0.032959)
    let g0 = f32(0.35)
    let g1 = f32(0.3)
    let g2 = f32(0.25)
    let g3 = f32(0.2)
    let one = f32(1.0)
    let two = f32(2.0)
    var acc = f32(0.0)
    var i = 0
    while i < n {
        p0 = p0 + i0
        if p0 > one { p0 = p0 - two }
        p1 = p1 + i1
        if p1 > one { p1 = p1 - two }
        p2 = p2 + i2
        if p2 > one { p2 = p2 - two }
        p3 = p3 + i3
        if p3 > one { p3 = p3 - two }
        let mixed = p0 * g0 + p1 * g1 + p2 * g2 + p3 * g3
        acc = acc + mixed
        i = i + 1
    }
    f64(acc)
}

fn main {
    let n = 2000000
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
    env.out("bench mix04 samples {n} ns {best} check {check}")
}
