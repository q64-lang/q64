//! bench: wavetable16 — a 16-entry wavetable oscillator with linear
//! interpolation. Integer phase + fractional part are tracked separately
//! (no float→int per sample), so the per-sample work is two table reads
//! at a variable index, one lerp, and three wrap branches.
//!
//! Everything lives in `main`: v0 array literals only compile in `main`
//! (UnsupportedExpression in any other function), and the table is f64
//! because v0 array literals are f64. The timing loop repeats the whole
//! kernel inline instead of calling a `pass` helper.

fn main {
    let n = 2000000
    var best = 999999999999
    var check = 0.0
    let table = [0.0, 0.38268, 0.70711, 0.92388,
                 1.0, 0.92388, 0.70711, 0.38268,
                 0.0, -0.38268, -0.70711, -0.92388,
                 -1.0, -0.92388, -0.70711, -0.38268]
    var rep = 0
    while rep < 7 {
        let t0 = env.time.monotonic_ns()
        var idx = 0
        var frac = 0.0
        let finc = 0.37
        var acc = 0.0
        var i = 0
        while i < n {
            frac = frac + finc
            if frac >= 1.0 {
                frac = frac - 1.0
                idx = idx + 1
            }
            if idx >= 16 { idx = 0 }
            var j = idx + 1
            if j >= 16 { j = 0 }
            let y = table[idx] * (1.0 - frac) + table[j] * frac
            acc = acc + y * y
            i = i + 1
        }
        let t1 = env.time.monotonic_ns()
        let dt = t1 - t0
        if dt < best { best = dt }
        check = acc
        rep = rep + 1
    }
    env.out("bench wavetable16 samples {n} ns {best} check {check}")
}
