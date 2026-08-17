//! Host calibration probe — not a benchmark kernel, run by run.sh before
//! the suite. Seventeen live f32 chains put it just past the >16-live-f32
//! threshold where a Debug-built q64-wasmtime-host executes ~100x slower
//! (bench/README.md, finding 1). On a release-built host this loop costs
//! well under 1 ms; on a Debug host it costs tens of ms, and run.sh
//! refuses to produce numbers that would be off by two orders of magnitude.

fn pass(n: i64) -> f64 {
    var v0 = f32(1.0)
    var v1 = f32(1.0)
    var v2 = f32(1.0)
    var v3 = f32(1.0)
    var v4 = f32(1.0)
    var v5 = f32(1.0)
    var v6 = f32(1.0)
    var v7 = f32(1.0)
    var v8 = f32(1.0)
    var v9 = f32(1.0)
    var v10 = f32(1.0)
    var v11 = f32(1.0)
    var v12 = f32(1.0)
    var v13 = f32(1.0)
    var v14 = f32(1.0)
    var v15 = f32(1.0)
    var v16 = f32(1.0)
    let r = f32(0.9999995)
    var i = 0
    while i < n {
        v0 = v0 * r
        v1 = v1 * r
        v2 = v2 * r
        v3 = v3 * r
        v4 = v4 * r
        v5 = v5 * r
        v6 = v6 * r
        v7 = v7 * r
        v8 = v8 * r
        v9 = v9 * r
        v10 = v10 * r
        v11 = v11 * r
        v12 = v12 * r
        v13 = v13 * r
        v14 = v14 * r
        v15 = v15 * r
        v16 = v16 * r
        i = i + 1
    }
    f64(v0) + f64(v8) + f64(v16)
}

fn main {
    let t0 = env.time.monotonic_ns()
    let c = pass(200000)
    let t1 = env.time.monotonic_ns()
    let d = t1 - t0
    env.out("calibrate ns {d} check {c}")
}
