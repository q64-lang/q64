//! bench: softclip — cubic soft clipper over a saw whose drive sweeps
//! through the knee, so both the polynomial path and the clamp branches
//! are exercised. The waveshaping/nonlinearity workload.

fn pass(n: i64) -> f64 {
    var ph = f32(0.0)
    let inc = f32(0.010986)
    var drive = f32(0.5)
    var dinc = f32(0.0000037)
    let one = f32(1.0)
    let neg_one = f32(-1.0)
    let two = f32(2.0)
    var acc = f32(0.0)
    var i = 0
    while i < n {
        ph = ph + inc
        if ph > one { ph = ph - two }
        drive = drive + dinc
        if drive > two { dinc = f32(-0.0000037) }
        if drive < f32(0.5) { dinc = f32(0.0000037) }
        let x = ph * drive
        var y = x * (f32(1.5) - f32(0.5) * x * x)
        if x > one { y = one }
        if x < neg_one { y = neg_one }
        acc = acc + y
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
    env.out("bench softclip samples {n} ns {best} check {check}")
}
